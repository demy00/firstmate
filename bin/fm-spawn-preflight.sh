#!/usr/bin/env bash
# fm-spawn-preflight.sh - check, before a worker is launched, that the shared
# machine resources its brief declares are present, and refuse with one
# blocker line naming every missing one.
#
# Usage: fm-spawn-preflight.sh <brief-file>
#
# A brief declares what its task needs in an optional top-level `# Needs`
# section, one bullet per need. Firstmate adds the section by hand after
# scaffolding (bin/fm-brief.sh) when the task needs a container stack, a
# toolchain, a credential, or a running app; the worker reads the same section
# in its launch brief. A brief without the section gets no checks at all: needs
# are never guessed from the project, the task, or the brief's other text.
# This header is the single owner of the section's syntax and of each check.
#
#   # Needs
#   - tool: cargo
#   - env: GITHUB_TOKEN
#   - env: OPENROUTER_API_KEY from ~/.config/demo/env
#   - file: ~/.config/gcloud/application_default_credentials.json
#   - app: Paper
#   - docker-disk: 12G
#   - docker-networks: 2
#
#   tool: <command>        the command is on this PATH (command -v).
#   env: <NAME>            the variable is set and nonempty in the spawning
#                          firstmate's environment.
#   env: <NAME> from <file>
#                          <file> is readable and assigns NAME a nonempty value
#                          on a `NAME=` or `export NAME=` line. The value is
#                          never printed.
#   file: <path>           the file exists and is nonempty.
#   app: <process name>    a process with exactly that name is running
#                          (pgrep -x), such as Paper for Paper Desktop.
#   docker-disk: <size>    Docker's own disk has at least <size> free, measured
#                          inside a throwaway busybox container with no network
#                          (df -Pk /). <size> is a number with a K, M, G, or T
#                          unit, optionally followed by B: 500M, 12G, 1.5TB.
#   docker-networks: <n>   <n> more Docker networks can be created right now
#                          (1-64). The check creates that many uniquely named,
#                          labelled (fm.preflight=1) networks and removes every
#                          one it created before it reports, because Docker
#                          does not expose its address-pool capacity.
#
# Paths may start with `~/`, which resolves against $HOME. Blank lines are
# allowed; every other line in the section must be one need. A `# Needs`
# heading inside a fenced code block is an example, not a declaration
# (bin/fm-brief-heading-lib.sh owns section reading).
#
# Exit status:
#   0  nothing declared, or every declared need is present; prints nothing.
#   1  one or more needs are missing; prints exactly one stderr line,
#      "error: spawn preflight refused <brief>: <what is missing>; <...>".
#   2  usage error, unreadable brief, or a malformed need; prints the line and
#      runs no check, so a typo can never silently skip one.
#
# bin/fm-spawn.sh runs this on every fresh ship or scout spawn before any lock,
# endpoint, worktree, or record exists, and refuses on a non-zero exit. A
# relaunch is exempt: it replaces the agent of a task that already exists.
# Firstmate may also run it by hand on a brief before spawning.
set -u

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=bin/fm-brief-heading-lib.sh
. "$SCRIPT_DIR/fm-brief-heading-lib.sh"

DOCKER_PROBE_IMAGE=busybox:1.36
MAX_NETWORK_PROBES=64

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}

die_usage() {
  echo "error: $*" >&2
  exit 2
}

expand_home() {  # <path>
  # shellcheck disable=SC2088 # The literal ~/ prefix is what the brief wrote.
  case "$1" in
  '~/'*) printf '%s/%s\n' "${HOME:-}" "${1#'~/'}" ;;
  *) printf '%s\n' "$1" ;;
  esac
}

valid_env_name() {  # <name>
  case "$1" in
  '' | [0-9]* | *[!A-Za-z0-9_]*) return 1 ;;
  esac
}

size_to_kb() {  # <size> -> kilobytes, or non-zero for an invalid size
  local size
  size=$(printf '%s' "$1" | tr '[:lower:]' '[:upper:]')
  case "$size" in
  *B) size=${size%B} ;;
  esac
  awk -v s="$size" 'BEGIN {
    if (s !~ /^[0-9]+(\.[0-9]+)?[KMGT]$/) exit 1
    unit = substr(s, length(s), 1)
    n = substr(s, 1, length(s) - 1) + 0
    f = (unit == "K") ? 1 : (unit == "M") ? 1024 : (unit == "G") ? 1048576 : 1073741824
    kb = n * f
    if (kb < 1) exit 1
    printf "%d\n", kb
  }'
}

kb_to_human() {  # <kilobytes>
  awk -v k="$1" 'BEGIN {
    if (k >= 1048576) printf "%.1fG\n", k / 1048576
    else printf "%.0fM\n", k / 1024
  }'
}

# env-file assignment: true when <file> assigns <name> a nonempty value.
env_file_assigns() {  # <file> <name>
  awk -v name="$2" '
    {
      line = $0
      sub(/^[[:space:]]*/, "", line)
      sub(/^export[[:space:]]+/, "", line)
      if (index(line, name "=") != 1) next
      value = substr(line, length(name) + 2)
      sub(/[[:space:]]+$/, "", value)
      if (value == "" || value == "\"\"" || value == "'\'''\''") next
      found = 1
    }
    END { exit found ? 0 : 1 }
  ' "$1"
}

# --- arguments ----------------------------------------------------------------
case "${1:-}" in
-h | --help)
  usage
  exit 0
  ;;
'') die_usage "brief file required (see --help)" ;;
esac
[ "$#" -eq 1 ] || die_usage "expected exactly one brief file (see --help)"
BRIEF=$1
[ -f "$BRIEF" ] && [ -r "$BRIEF" ] || die_usage "brief $BRIEF is not a readable file"

fm_brief_heading_present "$BRIEF" "# Needs" || exit 0
NEEDS_BODY=$(fm_brief_heading_body "$BRIEF" "# Needs")

# --- parse every need before checking any -------------------------------------
KINDS=()
VALUES=()
while IFS= read -r raw || [ -n "$raw" ]; do
  line=$(printf '%s' "$raw" | sed -e 's/[[:space:]]*$//')
  [ -n "$line" ] || continue
  bad="$BRIEF # Needs line '$raw' is not a valid need (kinds: tool, env, file, app, docker-disk, docker-networks; see bin/fm-spawn-preflight.sh --help)"
  case "$line" in
  '- '*:*) ;;
  *) die_usage "$bad" ;;
  esac
  entry=${line#- }
  kind=${entry%%:*}
  value=${entry#*:}
  value=$(printf '%s' "$value" | sed -e 's/^[[:space:]]*//')
  [ -n "$value" ] || die_usage "$bad"
  case "$kind" in
  tool)
    case "$value" in *[[:space:]]*) die_usage "$bad" ;; esac
    ;;
  env)
    name=${value%% *}
    valid_env_name "$name" || die_usage "$bad"
    if [ "$name" != "$value" ]; then
      rest=${value#"$name"}
      rest=$(printf '%s' "$rest" | sed -e 's/^[[:space:]]*//')
      case "$rest" in
      'from '*) ;;
      *) die_usage "$bad" ;;
      esac
      path=$(printf '%s' "${rest#from }" | sed -e 's/^[[:space:]]*//')
      [ -n "$path" ] || die_usage "$bad"
      value="$name from $path"
    fi
    ;;
  file | app) ;;
  docker-disk)
    size_to_kb "$value" >/dev/null || die_usage "$bad"
    ;;
  docker-networks)
    case "$value" in '' | *[!0-9]* | 0*) die_usage "$bad" ;; esac
    [ "$value" -le "$MAX_NETWORK_PROBES" ] || die_usage "$bad"
    ;;
  *) die_usage "$bad" ;;
  esac
  KINDS+=("$kind")
  VALUES+=("$value")
done <<EOF
$NEEDS_BODY
EOF

[ "${#KINDS[@]}" -gt 0 ] || exit 0

# --- checks -----------------------------------------------------------------------
MISSING=()
DOCKER_STATE=unknown

docker_reachable() {
  if [ "$DOCKER_STATE" = unknown ]; then
    if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
      DOCKER_STATE=up
    else
      DOCKER_STATE=down
      MISSING+=("Docker is not running (docker info failed)")
    fi
  fi
  [ "$DOCKER_STATE" = up ]
}

check_docker_disk() {  # <size>
  local need_kb free_kb
  need_kb=$(size_to_kb "$1")
  free_kb=$(docker run --rm --network none "$DOCKER_PROBE_IMAGE" df -Pk / 2>/dev/null |
    awk 'NR == 2 { print $4 }')
  case "$free_kb" in
  '' | *[!0-9]*)
    MISSING+=("Docker disk free space could not be measured (docker run $DOCKER_PROBE_IMAGE df failed)")
    return
    ;;
  esac
  if [ "$free_kb" -lt "$need_kb" ]; then
    MISSING+=("Docker disk has $(kb_to_human "$free_kb") free, the task needs $1 (see docker system df)")
  fi
}

# Probe networks live on the Docker engine every lane shares, so an interrupted
# probe still removes the ones it made.
PROBE_NETWORKS=()
remove_probe_networks() {
  [ "${#PROBE_NETWORKS[@]}" -gt 0 ] || return 0
  if ! docker network rm "${PROBE_NETWORKS[@]}" >/dev/null 2>&1; then
    MISSING+=("preflight probe networks ${PROBE_NETWORKS[*]} could not be removed (docker network rm them)")
  fi
  PROBE_NETWORKS=()
}
trap 'remove_probe_networks; exit 130' INT TERM HUP

check_docker_networks() {  # <count>
  local want=$1 i name made=0
  for ((i = 1; i <= want; i++)); do
    name="fm-preflight-$$-$i"
    if docker network create --label fm.preflight=1 "$name" >/dev/null 2>&1; then
      PROBE_NETWORKS+=("$name")
      made=$((made + 1))
    else
      break
    fi
  done
  remove_probe_networks
  if [ "$made" -lt "$want" ]; then
    MISSING+=("only $made of $want new Docker networks can be created (address pool full; see docker network ls)")
  fi
}

for idx in "${!KINDS[@]}"; do
  kind=${KINDS[$idx]}
  value=${VALUES[$idx]}
  case "$kind" in
  tool)
    command -v -- "$value" >/dev/null 2>&1 || MISSING+=("tool $value is not on PATH")
    ;;
  env)
    case "$value" in
    *' from '*)
      name=${value%% from *}
      path=$(expand_home "${value#* from }")
      if [ ! -r "$path" ] || [ ! -f "$path" ]; then
        MISSING+=("$name: $path is not readable")
      elif ! env_file_assigns "$path" "$name"; then
        MISSING+=("$name is not set in $path")
      fi
      ;;
    *)
      [ -n "$(printenv "$value" 2>/dev/null)" ] || MISSING+=("environment variable $value is not set")
      ;;
    esac
    ;;
  file)
    path=$(expand_home "$value")
    [ -f "$path" ] && [ -s "$path" ] || MISSING+=("file $path is missing or empty")
    ;;
  app)
    pgrep -x -- "$value" >/dev/null 2>&1 || MISSING+=("app $value is not running")
    ;;
  docker-disk)
    docker_reachable && check_docker_disk "$value"
    ;;
  docker-networks)
    docker_reachable && check_docker_networks "$value"
    ;;
  esac
done

[ "${#MISSING[@]}" -gt 0 ] || exit 0
joined=
for item in "${MISSING[@]}"; do
  joined="${joined:+$joined; }$item"
done
echo "error: spawn preflight refused $BRIEF: $joined" >&2
exit 1
