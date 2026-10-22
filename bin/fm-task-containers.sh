#!/usr/bin/env bash
# List or stop the running Docker containers a task can be proved to own.
#
# Usage: fm-task-containers.sh list|stop --task <id> [--worktree <dir>]
#          [--worktree-since <YYYY-MM-DDTHH:MM:SSZ>] [--tasktmp <dir>]
#
# Workers start Docker stacks - demo environments, end-to-end databases, an
# identity provider for a pipeline test - and Docker keeps them running after
# the worker exits and its worktree is returned. Nothing else records that a
# container came from a task, so bin/fm-teardown.sh calls `stop` before it
# removes the worktree, and a finished task no longer leaves load behind.
#
# Ownership is read from what Docker itself records for every container, never
# from names or ages: the compose project's working dir and config files
# (labels compose stamps on each service container) and each bind-mount
# source. A container is the task's when any of those paths is one of the
# task's own roots or lies under it:
#   - the task worktree (--worktree);
#   - the per-task temp root (--tasktmp);
#   - a no-mistakes run worktree of this repo whose run is on the worktree's
#     current branch. The run worktrees live under
#     <no-mistakes home>/worktrees/<repo hash>/<run id>/, where the repo hash
#     is read from the worktree's `no-mistakes` remote
#     (<no-mistakes home>/repos/<repo hash>.git) and the run's branch from
#     `no-mistakes axi status --run <run id>`. A run that cannot be looked up
#     proves nothing and its containers are left alone.
# A pool slot is reused across tasks, so a path in the worktree alone cannot
# separate this task's container from one an earlier holder left running.
# --worktree-since gives the time this task took the slot, and a container
# whose current start time is earlier is not counted as the task's through the
# worktree. The temp root and run worktrees are unique to the task and need no
# such bound.
# Containers with none of these paths - a plain `docker run` with only named
# volumes, or a stack composed from a directory outside the task - cannot be
# attributed and are never touched; the ship and scout briefs tell workers to
# keep stack files inside their worktree and to stop their own stacks before
# reporting done.
#
# `stop` runs `docker stop` (never rm, never volume removal) on the proved
# containers only, and prints one line per container. `list` prints the same
# lines as "would stop" and changes nothing. Docker that is not installed or
# not reachable is reported in one line and is not a failure. Exits 0 when
# every proved container stopped or nothing was proved, 1 when a container
# would not stop, and 2 on a usage error.
set -u
export LC_ALL=C

SCRIPT_DIR=$(CDPATH='' cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)

# shellcheck source=bin/fm-timeout-lib.sh
. "$SCRIPT_DIR/fm-timeout-lib.sh"
# shellcheck source=bin/fm-nm-run-lib.sh
. "$SCRIPT_DIR/fm-nm-run-lib.sh"

DOCKER=docker
# Test-only seam: tests/lib.sh points this at an absent command so no suite
# reaches the real Docker engine, and docker cases point it at a fake.
if [ "${FM_TEST_SEAM:-}" = 1 ] && [ -n "${FM_TEST_DOCKER:-}" ]; then
  DOCKER=$FM_TEST_DOCKER
fi
DOCKER_QUERY_TIMEOUT=20
DOCKER_STOP_TIMEOUT=90
NM_LOOKUP_TIMEOUT=10

usage() {
  cat <<'TXT'
Usage: fm-task-containers.sh list|stop --task <id> [--worktree <dir>]
         [--worktree-since <YYYY-MM-DDTHH:MM:SSZ>] [--tasktmp <dir>]

Stop (or, with list, only report) the running Docker containers whose compose
working dir, compose config files, or bind mounts lie in the task's worktree,
its temp root, or one of its no-mistakes run worktrees. Containers that cannot
be proved to be the task's are never touched. Read this script's header for
the full ownership rule.
TXT
}

die_usage() { printf 'fm-task-containers: %s\n' "$1" >&2; usage >&2; exit 2; }

ACTION=${1:-}
case "$ACTION" in
  list|stop) shift ;;
  -h|--help) usage; exit 0 ;;
  *) die_usage "expected list or stop" ;;
esac
TASK='' WT='' SINCE='' TASKTMP=''
while [ $# -gt 0 ]; do
  case "$1" in
    --task|--worktree|--worktree-since|--tasktmp)
      [ $# -ge 2 ] || die_usage "$1 needs a value"
      case "$1" in
        --task) TASK=$2 ;;
        --worktree) WT=$2 ;;
        --worktree-since) SINCE=$2 ;;
        --tasktmp) TASKTMP=$2 ;;
      esac
      shift 2
      ;;
    -h|--help) usage; exit 0 ;;
    *) die_usage "unknown argument: $1" ;;
  esac
done
[ -n "$TASK" ] || die_usage "--task is required"
case "$SINCE" in
  '') ;;
  [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]Z) SINCE=${SINCE%Z} ;;
  *) die_usage "--worktree-since must be a UTC time like 2026-10-15T10:00:00Z" ;;
esac

# Roots as parallel arrays: path, description, and whether the worktree's
# start bound applies. Each existing root is also added in its physical form,
# because Docker records a path as it was given (/tmp/x and /private/tmp/x are
# the same directory on macOS).
ROOT_PATHS=() ROOT_DESCS=() ROOT_BOUNDED=()
add_root() {  # <path> <description> <bounded 0|1>
  local path=${1%/} physical
  [ -n "$path" ] || return 0
  ROOT_PATHS+=("$path"); ROOT_DESCS+=("$2"); ROOT_BOUNDED+=("$3")
  physical=$(CDPATH='' cd -- "$path" 2>/dev/null && pwd -P) || return 0
  [ "$physical" != "$path" ] || return 0
  ROOT_PATHS+=("$physical"); ROOT_DESCS+=("$2"); ROOT_BOUNDED+=("$3")
}
[ -z "$WT" ] || add_root "$WT" "the task worktree" 1
[ -z "$TASKTMP" ] || add_root "$TASKTMP" "the task temp dir" 0

# The worktree's no-mistakes run worktrees directory and branch, when both are
# readable; otherwise run worktrees prove nothing.
NM_WORKTREES='' BRANCH=''
if [ -n "$WT" ] && [ -d "$WT" ]; then
  nm_remote=$(git -C "$WT" remote get-url no-mistakes 2>/dev/null || true)
  case "$nm_remote" in
    /*/repos/*.git)
      nm_hash=${nm_remote##*/}; nm_hash=${nm_hash%.git}
      NM_WORKTREES="${nm_remote%/repos/*}/worktrees/$nm_hash"
      ;;
  esac
  BRANCH=$(git -C "$WT" symbolic-ref --quiet --short HEAD 2>/dev/null || true)
  [ -n "$BRANCH" ] || NM_WORKTREES=
fi

[ "${#ROOT_PATHS[@]}" -gt 0 ] || [ -n "$NM_WORKTREES" ] || exit 0

if ! command -v "$DOCKER" >/dev/null 2>&1; then
  echo "Docker is not installed; no containers to stop for $TASK"
  exit 0
fi

docker_unreachable() {  # <stderr>
  local why
  why=$(printf '%s\n' "$1" | sed -n '/./{p;q;}')
  echo "Docker is not reachable (${why:-no answer within ${DOCKER_QUERY_TIMEOUT}s}); $TASK's containers were not checked"
  exit 0
}

ERR=$(mktemp "${TMPDIR:-/tmp}/fm-task-containers.XXXXXX") || exit 1
trap 'rm -f "$ERR"' EXIT
IDS=$(fm_run_timed "$DOCKER_QUERY_TIMEOUT" "$DOCKER" ps -q --no-trunc 2>"$ERR") \
  || docker_unreachable "$(cat "$ERR")"
[ -n "$IDS" ] || exit 0
# shellcheck disable=SC2016 # A Go template for docker, not a shell expansion.
FORMAT='{{.Id}}{{"\x1f"}}{{.Name}}{{"\x1f"}}{{.State.StartedAt}}{{"\x1f"}}{{with index .Config.Labels "com.docker.compose.project.working_dir"}}{{.}}{{end}}{{"\x1f"}}{{with index .Config.Labels "com.docker.compose.project.config_files"}}{{.}}{{end}}{{range .Mounts}}{{if eq .Type "bind"}}{{"\x1f"}}{{.Source}}{{end}}{{end}}'
# shellcheck disable=SC2086 # Container ids are hex words, one per line.
INSPECT=$(fm_run_timed "$DOCKER_QUERY_TIMEOUT" "$DOCKER" inspect --format "$FORMAT" $IDS 2>"$ERR") \
  || docker_unreachable "$(cat "$ERR")"

# Branch of a no-mistakes run, cached per run id; empty when it cannot be read.
NM_RUN_IDS=() NM_RUN_BRANCHES=()
nm_run_branch() {  # <run-id>
  local run=$1 i out branch=
  for i in "${!NM_RUN_IDS[@]}"; do
    [ "${NM_RUN_IDS[$i]}" = "$run" ] && { printf '%s' "${NM_RUN_BRANCHES[$i]}"; return 0; }
  done
  if command -v no-mistakes >/dev/null 2>&1 \
     && out=$(cd "$WT" && fm_run_timed "$NM_LOOKUP_TIMEOUT" no-mistakes axi status --run "$run" 2>/dev/null) \
     && [ "$(fm_nm_strip_quotes "$(fm_nm_field "$out" id)")" = "$run" ]; then
    branch=$(fm_nm_strip_quotes "$(fm_nm_field "$out" branch)")
  fi
  NM_RUN_IDS+=("$run"); NM_RUN_BRANCHES+=("$branch")
  printf '%s' "$branch"
}

# Why <path> proves ownership, for a container started at <started>; empty
# output and a non-zero status when it proves nothing.
path_reason() {  # <path> <started>
  local path=$1 started=$2 i root rest run
  [ -n "$path" ] || return 1
  for i in "${!ROOT_PATHS[@]}"; do
    root=${ROOT_PATHS[$i]}
    case "$path" in "$root"|"$root"/*) ;; *) continue ;; esac
    if [ "${ROOT_BOUNDED[$i]}" = 1 ] && [ -n "$SINCE" ] && [[ "${started:0:19}" < "$SINCE" ]]; then
      continue
    fi
    printf 'is in %s' "${ROOT_DESCS[$i]}"
    return 0
  done
  [ -n "$NM_WORKTREES" ] || return 1
  case "$path" in "$NM_WORKTREES"/?*) ;; *) return 1 ;; esac
  rest=${path#"$NM_WORKTREES"/}
  run=${rest%%/*}
  case "$run" in *[!0-9A-Za-z]*) return 1 ;; esac
  [ "$(nm_run_branch "$run")" = "$BRANCH" ] || return 1
  printf "is in no-mistakes run %s's worktree for %s" "$run" "$BRANCH"
}

# Each proved container as "<id>\t<name>\t<evidence>".
PROVED=()
while IFS=$'\x1f' read -r -a fields; do
  [ "${#fields[@]}" -ge 3 ] || continue
  id=${fields[0]} name=${fields[1]#/} started=${fields[2]}
  evidence=
  if [ -n "${fields[3]:-}" ] && reason=$(path_reason "${fields[3]}" "$started"); then
    evidence="compose working dir ${fields[3]} $reason"
  fi
  if [ -z "$evidence" ] && [ -n "${fields[4]:-}" ]; then
    IFS=, read -r -a configs <<< "${fields[4]}"
    for config in "${configs[@]}"; do
      if reason=$(path_reason "$config" "$started"); then
        evidence="compose config file $config $reason"
        break
      fi
    done
  fi
  if [ -z "$evidence" ]; then
    for src in "${fields[@]:5}"; do
      if reason=$(path_reason "$src" "$started"); then
        evidence="bind mount $src $reason"
        break
      fi
    done
  fi
  [ -z "$evidence" ] || PROVED+=("$id"$'\t'"$name"$'\t'"$evidence")
done <<< "$INSPECT"
[ "${#PROVED[@]}" -gt 0 ] || exit 0

if [ "$ACTION" = list ]; then
  for entry in "${PROVED[@]}"; do
    IFS=$'\t' read -r id name evidence <<< "$entry"
    echo "would stop Docker container $name (${id:0:12}) for $TASK: $evidence"
  done
  exit 0
fi

STOP_IDS=()
for entry in "${PROVED[@]}"; do STOP_IDS+=("${entry%%$'\t'*}"); done
STOPPED=$(fm_run_timed "$DOCKER_STOP_TIMEOUT" "$DOCKER" stop "${STOP_IDS[@]}" 2>"$ERR") || true
rc=0
for entry in "${PROVED[@]}"; do
  IFS=$'\t' read -r id name evidence <<< "$entry"
  if printf '%s\n' "$STOPPED" | grep -Fxq -- "$id"; then
    echo "stopped Docker container $name (${id:0:12}) for $TASK: $evidence"
  else
    echo "could not stop Docker container $name (${id:0:12}) for $TASK: $evidence; stop it by hand with docker stop ${id:0:12}"
    rc=1
  fi
done
if [ "$rc" != 0 ] && [ -s "$ERR" ]; then
  sed 's/^/docker: /' "$ERR"
fi
exit "$rc"
