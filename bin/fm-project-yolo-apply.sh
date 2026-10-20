#!/usr/bin/env bash
# Apply a project's REGISTERED yolo posture to this home's live ship tasks of
# that project. A ship task records its yolo= merge authority in
# state/<id>.meta at spawn or promotion, and every merge decision reads that
# record, so a captain change to the project's +yolo token in data/projects.md
# reaches no task that is already running until this command rewrites it.
# Firstmate runs it right after making that registry change, in either
# direction: switching +yolo on hands the project's running ships routine
# merge authority, and switching it off takes that authority back.
#
# The posture comes only from bin/fm-project-mode.sh, which owns the registry:
# a forge=gerrit project always reports yolo=off, an unregistered project
# resolves to off with its warning passed through, and a registry entry that
# does not resolve (its refusal is passed through) changes no task at all.
# Only yolo= changes. Delivery mode, branch, and every other field keep their
# recorded values, and scouts and secondmates, which carry no merge posture,
# are never touched. Merge authority stays exactly what yolo always meant:
# bin/fm-pr-merge.sh's green-head, red-check, and away-record gates, and the
# escalation of destructive, irreversible, and security-sensitive merges, are
# unchanged by this record.
#
# Each task is rewritten under its lifecycle lock (state/.control-<id>.lock,
# tried once so a running relaunch or promotion is never raced) and its meta
# lock, then published atomically. A task whose lifecycle lock is busy is
# skipped and named; the command then exits 1 and is safe to rerun, because a
# task already carrying the posture is reported unchanged.
#
# Usage: fm-project-yolo-apply.sh <project> [<task-id>...]
#   <project> is the registry name, matched against the basename of each
#   task's recorded project= path. Named task ids limit the apply to those
#   tasks; each must be a live ship task of <project>, or nothing is changed.
#   Prints one line per task ("<id>: yolo <old> -> <new>" or
#   "<id>: yolo <value> (unchanged)") and a closing summary.
#   Exit 0 when every task carries the posture, 1 when a task was skipped or
#   could not be rewritten or the registry posture does not resolve, and 2 on
#   a usage error.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

usage() {
  sed -n '/^# Usage:/,/^set -eu/p' "${BASH_SOURCE[0]}" | sed '$d' | sed 's/^# \{0,1\}//'
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
  ''|-*) echo "usage: fm-project-yolo-apply.sh <project> [<task-id>...]" >&2; exit 2 ;;
esac
PROJECT=$1
shift

# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-tasks-axi-lib.sh
. "$SCRIPT_DIR/fm-tasks-axi-lib.sh"
# shellcheck source=bin/fm-backlog-transition-lib.sh
. "$SCRIPT_DIR/fm-backlog-transition-lib.sh"

[ -d "$STATE" ] || { echo "error: state dir not found: $STATE" >&2; exit 1; }

if ! POSTURE=$(FM_HOME="$FM_HOME" "$SCRIPT_DIR/fm-project-mode.sh" "$PROJECT"); then
  echo "error: the registry posture for $PROJECT does not resolve (see the refusal above); no task was changed" >&2
  exit 1
fi
YOLO=${POSTURE##* }
case "$YOLO" in
  on|off) ;;
  *) echo "error: the registry posture for $PROJECT is unreadable ('$POSTURE'); no task was changed" >&2; exit 1 ;;
esac

meta_value() {  # <meta> <key>
  grep "^$2=" "$1" 2>/dev/null | tail -1 | cut -d= -f2- || true
}

# 0 when <meta> is a regular task record of a ship task of PROJECT.
project_ship_meta() {  # <meta>
  local project kind
  [ -f "$1" ] && [ ! -L "$1" ] || return 1
  kind=$(meta_value "$1" kind)
  [ "$kind" = ship ] || return 1
  project=$(meta_value "$1" project)
  [ -n "$project" ] && [ "${project##*/}" = "$PROJECT" ]
}

TASKS=()
if [ "$#" -gt 0 ]; then
  for id in "$@"; do
    if ! fm_pr_task_id_valid "$id" || ! project_ship_meta "$STATE/$id.meta"; then
      echo "error: $id is not a live ship task of $PROJECT in this home; no task was changed" >&2
      exit 1
    fi
    TASKS+=("$id")
  done
else
  for meta in "$STATE"/*.meta; do
    project_ship_meta "$meta" || continue
    id=${meta##*/}
    TASKS+=("${id%.meta}")
  done
fi

CONTROL_LOCK=
CONTROL_LOCK_HELD=0
META_LOCK=
META_LOCK_HELD=0
TMP=
release_task_locks() {
  [ -z "$TMP" ] || rm -f -- "$TMP" 2>/dev/null || true
  TMP=
  if [ "$META_LOCK_HELD" = 1 ]; then
    META_LOCK_HELD=0
    fm_lock_release "$META_LOCK" || true
  fi
  if [ "$CONTROL_LOCK_HELD" = 1 ]; then
    CONTROL_LOCK_HELD=0
    fm_lock_release "$CONTROL_LOCK" || true
  fi
}
trap release_task_locks EXIT

# Rewrite one task's yolo= under its locks; prints the task's line. Returns 1
# when the task was skipped or could not be rewritten.
apply_task() {  # <task-id>
  local id=$1 meta=$STATE/$1.meta old
  CONTROL_LOCK="$STATE/.control-$id.lock"
  if ! fm_lock_try_acquire "$CONTROL_LOCK"; then
    echo "$id: skipped - another lifecycle action is running for it; rerun this command"
    return 1
  fi
  CONTROL_LOCK_HELD=1
  META_LOCK=$(fm_meta_lock_path "$meta") || { echo "$id: skipped - its metadata lock path is invalid"; return 1; }
  fm_lock_acquire_wait "$META_LOCK"
  META_LOCK_HELD=1
  if ! fm_backlog_record_present "$meta" "task record" "$STATE" || ! project_ship_meta "$meta"; then
    echo "$id: skipped - its task record is gone or no longer a ship task of $PROJECT"
    return 1
  fi
  old=$(meta_value "$meta" yolo)
  if [ "$old" = "$YOLO" ]; then
    echo "$id: yolo $YOLO (unchanged)"
    return 0
  fi
  TMP="$STATE/.$id.meta.yolo-apply.${BASHPID:-$$}"
  { grep -v '^yolo=' "$meta" || true; echo "yolo=$YOLO"; } > "$TMP"
  if ! fm_backlog_atomic_transition publish "$TMP" "$meta" "task record" "$STATE"; then
    echo "$id: skipped - its task record could not be published ($FM_BACKLOG_TRANSITION_ERROR)"
    return 1
  fi
  TMP=
  echo "$id: yolo ${old:-unset} -> $YOLO"
}

RC=0
for id in ${TASKS[@]+"${TASKS[@]}"}; do
  apply_task "$id" || RC=1
  release_task_locks
done
if [ "$RC" -eq 0 ]; then
  echo "applied: $PROJECT yolo=$YOLO to ${#TASKS[@]} live ship task(s) in this home"
else
  echo "incomplete: $PROJECT yolo=$YOLO was not applied to every live ship task; rerun after the skipped tasks' lifecycle actions finish" >&2
fi
exit "$RC"
