#!/usr/bin/env bash
# fm-claude-usage.sh - a Claude worker stopped by an account usage limit
# declares its own wait, with the reset time, and firstmate resumes it with one
# command once the limit resets.
#
# The account limit is shared, so it stops firstmate and every Claude worker in
# the same minute. A stopped worker's turn ends on Claude's limit message and
# the pane idles; before this script nothing appended a status line, so the
# watcher read the silence as a possible wedge, and every worker had to be told
# by hand to continue once the limit reset.
#
# The absorb path already exists and is unchanged here: a `paused:` line that
# names a usage limit and an `until <UTC>` time is absorbed until that time and
# surfaced once when it passes (bin/fm-classify-lib.sh owns the vocabulary;
# bin/fm-watch.sh and bin/fm-supervise-daemon.sh consume it). This script only
# writes that line automatically, from the harness's own signals, and adds no
# worker state, classification tier, or watcher check of its own.
#
# Subcommands:
#
#   stop-failure <state-dir> <id>
#       Claude's StopFailure hook (wired by bin/fm-spawn.sh). stdin is the hook
#       payload. When its `error` is `rate_limit` - the kind Claude Code reports
#       for every plan limit (session, 5-hour, weekly) - append to
#       <state-dir>/<id>.status:
#         paused [at=<now>]: usage limit - <Claude's own limit text> until <UTC>; ...
#       Any other error kind (server_error, authentication_failed, ...) is left
#       exactly as it behaves without this hook. Always exits 0: Claude ignores
#       this hook's result, and nothing here may disturb the worker's lifecycle.
#
#   turn-start <state-dir> <id>
#       Claude's UserPromptSubmit hook. When the latest declared wait is one
#       stop-failure wrote, append `resolved` to close it: a new turn means the
#       worker is no longer idling on the limit (see cmd_turn_start). Any other
#       pause is left alone. Always exits 0, for the same reason as above.
#
#   resume <id>... | resume --due
#       Firstmate's recovery step, run with FM_HOME set as for bin/fm-send.sh.
#       Claude normally continues by itself after the reset, and turn-start
#       then closes the wait; resume is for a worker the reset left idle, such
#       as one whose automatic continue was off, cancelled by an Escape, or
#       predates it. For each named task whose declared wait is a usage limit,
#       this refuses while the declared reset is still ahead (naming it), and
#       otherwise steers the worker through bin/fm-send.sh to continue where
#       it stopped - its own conversation still holds that point - then
#       appends `resolved` to close the wait. `--due` selects every live task
#       in the home whose wait this script declared and whose reset has
#       passed, so one freeze is recovered with one command. Exits 0 when
#       every selected task was resumed, 1 when any was refused or failed.
#
# Reset time. `until` comes from Claude's own limit text, "You've hit your
# session limit · resets 11:40am (Europe/Budapest)" or "... resets Oct 7 at 5pm
# (Africa/Casablanca)": the minute after the next such wall-clock time in the
# named zone, because Claude floors the reset it shows to the minute. A text
# with no readable reset or zone declares the wait without `until`, so the
# watcher's ordinary pause cadence rechecks it rather than a guessed time.
#
# FM_CLAUDE_USAGE_NOW overrides the clock (epoch seconds) for tests.
set -u

usage() {
  cat >&2 <<'EOF'
usage:
  fm-claude-usage.sh stop-failure <state-dir> <id>   # stdin: Claude StopFailure hook payload
  fm-claude-usage.sh turn-start <state-dir> <id>     # Claude UserPromptSubmit hook
  fm-claude-usage.sh resume <id>...                  # FM_HOME set: steer workers whose limit reset
  fm-claude-usage.sh resume --due                    # every worker this home's limit stop has freed
See the header comment for the full contract.
EOF
  exit 2
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-classify-lib.sh
. "$SCRIPT_DIR/fm-classify-lib.sh"

# The marker every declaration this script writes carries, so turn-start and
# resume --due act only on waits it declared, never on a pause someone chose for
# another reason.
DECLARED_MARKER='bin/fm-claude-usage.sh resume'

now_epoch() { printf '%s' "${FM_CLAUDE_USAGE_NOW:-$(date +%s)}"; }

# Wall-clock "YYYY-MM-DD HH:MM" in <zone> -> epoch, BSD then GNU date.
zone_wall_to_epoch() {  # <zone> <YYYY-MM-DD HH:MM>
  TZ=$1 date -j -f '%Y-%m-%d %H:%M:%S' "$2:00" +%s 2>/dev/null \
    || TZ=$1 date -d "$2" +%s 2>/dev/null
}

# Format <epoch> in <zone> with a strftime <format>, BSD then GNU date.
zone_format() {  # <zone> <epoch> <format>
  TZ=$1 date -r "$2" "+$3" 2>/dev/null || TZ=$1 date -d "@$2" "+$3" 2>/dev/null
}

utc_minute() {  # <epoch> -> YYYY-MM-DDTHH:MMZ, rounded up to the minute
  local e=$1
  [ $((e % 60)) -eq 0 ] || e=$(( e - e % 60 + 60 ))
  zone_format UTC "$e" '%Y-%m-%dT%H:%MZ'
}

# "11:40am" / "12am" / "5pm" -> "HH:MM" (24-hour); nonzero on any other shape.
clock_24h() {  # <h[:mm]am|pm>
  local spec=$1 h m=00 half
  case "$spec" in
    *am) half=am ;;
    *pm) half=pm ;;
    *) return 1 ;;
  esac
  spec=${spec%"$half"}
  case "$spec" in
    *:*) h=${spec%%:*}; m=${spec#*:} ;;
    *) h=$spec ;;
  esac
  case "$h" in ''|*[!0-9]*) return 1 ;; esac
  case "$m" in [0-5][0-9]) ;; *) return 1 ;; esac
  h=$((10#$h))
  [ "$h" -ge 1 ] && [ "$h" -le 12 ] || return 1
  [ "$h" -eq 12 ] && h=0
  [ "$half" = pm ] && h=$((h + 12))
  printf '%02d:%s' "$h" "$m"
}

month_number() {  # <Mon> -> 01..12
  case "$1" in
    Jan) printf 01 ;; Feb) printf 02 ;; Mar) printf 03 ;; Apr) printf 04 ;;
    May) printf 05 ;; Jun) printf 06 ;; Jul) printf 07 ;; Aug) printf 08 ;;
    Sep) printf 09 ;; Oct) printf 10 ;; Nov) printf 11 ;; Dec) printf 12 ;;
    *) return 1 ;;
  esac
}

# The reset epoch named by Claude's limit text, the next such time after <now>.
# Claude shows the reset only to the minute, so a time up to RESET_GRACE_SECS
# behind <now> is that same reset, already due, rather than one a day or a year
# out. Nonzero when the text names no reset this reader understands.
RESET_GRACE_SECS=300
text_reset_epoch() {  # <text> <now>
  local text=$1 now=$2 spec zone clock day mon dnum year e
  case "$text" in *"resets "*"("*")"*) ;; *) return 1 ;; esac
  spec=${text##*resets }
  zone=${spec##*(}
  zone=${zone%%)*}
  spec=${spec%% (*}
  # A zone the system does not know would silently read as UTC.
  case "$zone" in ''|*[!A-Za-z0-9_/+-]*|/*|*..*) return 1 ;; esac
  [ -f "/usr/share/zoneinfo/$zone" ] || return 1
  case "$spec" in
    *" at "*)
      clock=$(clock_24h "${spec##* at }") || return 1
      day=${spec%% at *}
      mon=$(month_number "${day%% *}") || return 1
      dnum=${day#* }
      case "$dnum" in [1-9]|[1-3][0-9]) ;; *) return 1 ;; esac
      year=$(zone_format "$zone" "$now" '%Y') || return 1
      e=$(zone_wall_to_epoch "$zone" "$(printf '%s-%s-%02d %s' "$year" "$mon" "$((10#$dnum))" "$clock")") || return 1
      if [ "$e" -lt "$((now - RESET_GRACE_SECS))" ]; then
        e=$(zone_wall_to_epoch "$zone" "$(printf '%s-%s-%02d %s' "$((year + 1))" "$mon" "$((10#$dnum))" "$clock")") || return 1
      fi
      ;;
    *)
      clock=$(clock_24h "$spec") || return 1
      e=$(zone_wall_to_epoch "$zone" "$(zone_format "$zone" "$now" '%Y-%m-%d') $clock") || return 1
      if [ "$e" -lt "$((now - RESET_GRACE_SECS))" ]; then
        e=$(zone_wall_to_epoch "$zone" "$(zone_format "$zone" "$((now + 86400))" '%Y-%m-%d') $clock") || return 1
      fi
      ;;
  esac
  printf '%s' "$e"
}

# --- stop-failure -----------------------------------------------------------

cmd_stop_failure() {  # <state-dir> <id>
  local state=$1 id=$2 payload error text now reset note last
  payload=$(cat) || return 0
  error=$(printf '%s' "$payload" | jq -r '.error // empty' 2>/dev/null) || return 0
  [ "$error" = rate_limit ] || return 0
  text=$(printf '%s' "$payload" | jq -r '.last_assistant_message // empty' 2>/dev/null | tr -s '\n\r\t' '   ')
  text=${text%"${text##*[![:space:]]}"}
  [ -n "$text" ] || text="Claude reported a rate limit"
  now=$(now_epoch)
  note="usage limit - $text"
  if reset=$(text_reset_epoch "$text" "$now"); then
    # Claude floors the reset it shows to the minute (verified live, 2.1.319),
    # so the wait has certainly cleared one minute after the time it names.
    note="$note until $(utc_minute $((reset + 60)))"
  fi
  note="$note; after the reset: $DECLARED_MARKER $id"
  # One declaration per limit: a steer sent during the limit starts a turn that
  # fails the same way, and repeating a wait firstmate already holds would only
  # wake it again. A limit with a different reset is new news and is declared.
  last=$(last_status_line "$state/$id.status" 2>/dev/null)
  case "$last" in
    paused*": $note") return 0 ;;
  esac
  printf 'paused [at=%s]: %s\n' "$now" "$note" >> "$state/$id.status" 2>/dev/null || true
  return 0
}

# --- turn-start -------------------------------------------------------------

# Claude Code continues a limited session on its own at the reset
# (autoContinueAtUsageLimit, on by default since 2.1.234; verified live in the
# worker launch shape on 2.1.319), and that continue fires UserPromptSubmit like
# any other turn. A new turn means the worker is no longer idling on the limit,
# so the wait this script declared is closed. If the limit still holds, the turn
# fails and stop-failure declares it again.
cmd_turn_start() {  # <state-dir> <id>
  local state=$1 id=$2 line
  cat >/dev/null 2>&1 || true
  line=$(status_declared_wait_line "$state/$id.status" 2>/dev/null)
  status_is_usage_reset_wait "$line" || return 0
  case "$line" in *"$DECLARED_MARKER"*) ;; *) return 0 ;; esac
  printf 'resolved [at=%s]: a new turn started after the usage-limit stop\n' "$(now_epoch)" \
    >> "$state/$id.status" 2>/dev/null || true
  return 0
}

# --- resume -----------------------------------------------------------------

RESUME_TEXT="The account usage limit that ended your last turn has reset, so you can work again. Nothing was lost: your conversation still holds where you stopped. Continue the task from where you stopped. First re-check anything that was running when the limit hit, such as a background command or a no-mistakes run, because it may have failed on the same limit."

resume_one() {  # <state-dir> <id> <now>
  local state=$1 id=$2 now=$3 line until
  line=$(status_declared_wait_line "$state/$id.status")
  if ! status_is_usage_reset_wait "$line"; then
    printf 'refused %s: its latest status declares no usage-limit wait\n' "$id" >&2
    return 1
  fi
  if until=$(status_paused_until "$line") && [ "$now" -lt "$until" ]; then
    printf 'refused %s: its usage limit resets at %s, not yet\n' "$id" "$(utc_minute "$until")" >&2
    return 1
  fi
  if ! "$SCRIPT_DIR/fm-send.sh" "$id" "$RESUME_TEXT" >/dev/null; then
    printf 'failed %s: the resume steer was not delivered; nothing was closed\n' "$id" >&2
    return 1
  fi
  printf 'resolved [at=%s]: usage limit reset passed; firstmate steered the worker to continue\n' "$now" >> "$state/$id.status"
  printf 'resumed %s\n' "$id"
}

due_ids() {  # <state-dir> <now>
  local state=$1 now=$2 meta id line until
  for meta in "$state"/*.meta; do
    [ -f "$meta" ] || continue
    id=${meta##*/}
    id=${id%.meta}
    line=$(status_declared_wait_line "$state/$id.status")
    status_is_usage_reset_wait "$line" || continue
    case "$line" in *"$DECLARED_MARKER"*) ;; *) continue ;; esac
    until=$(status_paused_until "$line") || continue
    [ "$now" -ge "$until" ] || continue
    printf '%s\n' "$id"
  done
}

cmd_resume() {  # <id>... | --due
  local state now id rc=0
  local -a ids=()
  if [ -z "${FM_HOME:-}" ]; then
    echo "error: FM_HOME is not set; resume steers through bin/fm-send.sh, which needs an explicit firstmate home" >&2
    return 2
  fi
  state=${FM_STATE_OVERRIDE:-$FM_HOME/state}
  now=$(now_epoch)
  if [ "${1:-}" = --due ]; then
    [ "$#" -eq 1 ] || usage
    while IFS= read -r id; do
      [ -n "$id" ] && ids+=("$id")
    done < <(due_ids "$state" "$now")
    if [ "${#ids[@]}" -eq 0 ]; then
      echo "no worker is waiting on a usage limit that has reset"
      return 0
    fi
    set -- "${ids[@]}"
  fi
  [ "$#" -gt 0 ] || usage
  for id in "$@"; do
    case "$id" in ''|.*|*/*) echo "error: invalid task id '$id'" >&2; rc=1; continue ;; esac
    resume_one "$state" "$id" "$now" || rc=1
  done
  return "$rc"
}

# --- dispatch ---------------------------------------------------------------

[ "$#" -ge 1 ] || usage
CMD=$1
shift
case "$CMD" in
  stop-failure|turn-start)
    [ "$#" -eq 2 ] || usage
    [ -d "$1" ] || { echo "error: no such state dir: $1" >&2; exit 2; }
    case "$2" in ''|.*|*/*) echo "error: invalid task id '$2'" >&2; exit 2 ;; esac
    if [ "$CMD" = stop-failure ]; then cmd_stop_failure "$1" "$2"; else cmd_turn_start "$1" "$2"; fi
    exit 0
    ;;
  resume) cmd_resume "$@"; exit $? ;;
  -h|--help) usage ;;
  *) usage ;;
esac
