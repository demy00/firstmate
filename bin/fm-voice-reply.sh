#!/usr/bin/env bash
# fm-voice-reply.sh - Claude Stop hook that speaks a reply's 🔊 line on the Mac.
#
# docs/voice-replies.md owns what the feature does for the captain, and
# docs/configuration.md "Voice replies" owns the config/voice-replies schema.
# This header owns the mechanics.
#
# Registered once in the tracked .claude/settings.json with "async": true, so
# Claude Code runs it in the background and the session never waits for it.
# It is inert unless the home's gitignored config/voice-replies says mode=mac.
# Every other mode value, including the reserved phone and auto, is silent.
#
# Scope: it speaks only for a genuine primary home whose state dir exists
# (bin/fm-primary-scope-lib.sh): the main home, or a marked secondmate home
# whose OWN config/voice-replies turns it on (the file is not inherited). A
# linked crew or scout worktree never speaks, even when FM_HOME points at a
# configured home. It also stands down for Grok and for a Cursor payload.
#
# What is spoken: of last_assistant_message, the last line that starts with
# 🔊 after optional leading space and Markdown quote or emphasis marks
# (> * _). The marker, its variation selector, * and backticks are dropped and
# white space is collapsed. A reply without such a line is not spoken.
# Quiet hours (quiet=HH:MM-HH:MM, may wrap midnight) silence it.
#
# Superseded replies, per home:
#   - Each speakable reply writes a fresh token to state/.voice-reply.gen,
#     waits FM_VOICE_REPLIES_SETTLE seconds (default 2), and is dropped when a
#     newer reply has replaced the token meanwhile.
#   - Before speaking, it stops the say process recorded in
#     state/.voice-reply.speaker ("<say pid> <hook pid>"), but only while that
#     process is still the child of the hook that started it, so a recycled pid
#     is never signalled. A reply that loses the token after starting stops
#     its own speech.
#   - state/.voice-reply.last holds "<cksum of the line> <epoch>"; the same
#     line again within 120 seconds is not repeated.
# The spoken text itself is never written to state, a log, or output. The
# text reaches say on stdin, so a line starting with "-" is never an option.
#
# voice=<name> is passed to say -v only when `say -v ?` lists that exact
# name; otherwise the system default voice speaks, rather than nothing.
#
# The hook always exits 0 and prints nothing: an unreadable payload, missing
# jq or say, a scope miss, or a state-write failure is silence, never a
# blocked or noisy stop.
#
# Test seams (environment): FM_VOICE_REPLIES_SAY (the say executable),
# FM_VOICE_REPLIES_SETTLE (seconds, decimals allowed), FM_VOICE_REPLIES_CLOCK
# (HH:MM for the quiet-hours test), FM_VOICE_REPLIES_NOW (epoch seconds for
# the repeat window), and the FM_ROOT_OVERRIDE / FM_STATE_OVERRIDE /
# FM_CONFIG_OVERRIDE overrides every hook shares.
set -u
set -o pipefail

usage() {
  cat <<'EOF'
usage: fm-voice-reply.sh

Claude Stop hook. Reads the hook payload on stdin and speaks the reply's
🔊 line on the Mac when config/voice-replies says mode=mac.
See docs/voice-replies.md and the script header.
EOF
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
  "") ;;
  *) usage >&2; exit 2 ;;
esac

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"

# shellcheck source=bin/fm-primary-scope-lib.sh
. "$SCRIPT_DIR/fm-primary-scope-lib.sh" || exit 0

[ -z "${GROK_AGENT:-}${GROK_HOOK_EVENT:-}" ] || exit 0
[ -f "$CONFIG/voice-replies" ] || exit 0
[ ! -t 0 ] || exit 0
payload=$(cat || true)
command -v jq >/dev/null 2>&1 || exit 0
jq -e 'type == "object" and (has("cursor_version") or has("cursorVersion") | not)' \
  >/dev/null 2>&1 <<<"$payload" || exit 0
fm_primary_scope_matches "$FM_ROOT" "$STATE" || exit 0

# Lines are key=value with blank space around the key and value ignored; the
# last line for a key wins, and any other line is ignored.
mode='' voice='' quiet='' key='' value=''
while IFS= read -r line || [ -n "$line" ]; do
  case "$line" in *=*) ;; *) continue ;; esac
  key=$(printf '%s' "${line%%=*}" | tr -d '[:space:]')
  value=$(printf '%s' "${line#*=}" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
  case "$key" in
    mode) mode=$value ;;
    voice) voice=$value ;;
    quiet) quiet=$(printf '%s' "$value" | tr -d '[:space:]') ;;
  esac
done < "$CONFIG/voice-replies"
[ "$mode" = mac ] || exit 0

# minutes_of <HH:MM>: print minutes since midnight, or fail on a bad clock.
minutes_of() {
  case "$1" in
    [0-1][0-9]:[0-5][0-9]|2[0-3]:[0-5][0-9]) ;;
    *) return 1 ;;
  esac
  echo $((10#${1%%:*} * 60 + 10#${1#*:}))
}

if [ -n "$quiet" ]; then
  if q_start=$(minutes_of "${quiet%%-*}") && q_end=$(minutes_of "${quiet#*-}") \
    && [ "$q_start" -ne "$q_end" ] \
    && now_min=$(minutes_of "${FM_VOICE_REPLIES_CLOCK:-$(date +%H:%M)}"); then
    if [ "$q_start" -lt "$q_end" ]; then
      [ "$now_min" -ge "$q_start" ] && [ "$now_min" -lt "$q_end" ] && exit 0
    else
      { [ "$now_min" -ge "$q_start" ] || [ "$now_min" -lt "$q_end" ]; } && exit 0
    fi
  fi
fi

text=$(jq -r '
    .last_assistant_message // empty | strings
    | [splits("\r?\n") | sub("^[\\s>*_]+"; "") | select(startswith("🔊"))]
    | last // empty
    | ltrimstr("🔊") | ltrimstr("\ufe0f")
    | gsub("[*`]"; "") | gsub("\\s+"; " ") | gsub("^ | $"; "")
  ' <<<"$payload" 2>/dev/null) || exit 0
[ -n "$text" ] || exit 0

say_bin=${FM_VOICE_REPLIES_SAY:-say}
command -v "$say_bin" >/dev/null 2>&1 || exit 0

now=${FM_VOICE_REPLIES_NOW:-$(date +%s)}
case "$now" in ''|*[!0-9]*) exit 0 ;; esac
settle=${FM_VOICE_REPLIES_SETTLE:-2}
case "$settle" in
  ''|*[!0-9.]*|*.*.*|.*|*.) settle=2 ;;
esac

# write_record <path> <line>: replace a state record atomically.
write_record() {
  local tmp
  tmp=$(mktemp "$1.XXXXXX" 2>/dev/null) || return 1
  if printf '%s\n' "$2" > "$tmp" && mv -f "$tmp" "$1"; then
    return 0
  fi
  rm -f "$tmp"
  return 1
}

is_current() {
  local current=''
  IFS= read -r current 2>/dev/null < "$GEN" || return 1
  [ "$current" = "$token" ]
}

GEN="$STATE/.voice-reply.gen"
SPEAKER="$STATE/.voice-reply.speaker"
LAST="$STATE/.voice-reply.last"

# Claim the newest reply, then let a reply that supersedes it within the
# settle window take over.
token="$$.$now.$RANDOM"
write_record "$GEN" "$token" || exit 0
sleep "$settle"
is_current || exit 0

hash=$(printf '%s' "$text" | cksum | awk '{ print $1 "-" $2 }')
last_hash='' last_at=''
read -r last_hash last_at 2>/dev/null < "$LAST" || true
case "$last_at" in
  ''|*[!0-9]*) ;;
  *) [ "$last_hash" = "$hash" ] && [ $((now - last_at)) -lt 120 ] && exit 0 ;;
esac

# Cut off an older reply that is still speaking. The recorded say process is
# signalled only while it is still the child of the hook that started it.
old_pid='' old_parent=''
read -r old_pid old_parent 2>/dev/null < "$SPEAKER" || true
case "$old_pid$old_parent" in
  ''|*[!0-9]*) ;;
  *)
    if [ "$(ps -o ppid= -p "$old_pid" 2>/dev/null | tr -d ' ')" = "$old_parent" ]; then
      kill "$old_pid" 2>/dev/null || true
    fi
    ;;
esac

say_args=(-f -)
if [ -n "$voice" ] && "$say_bin" -v '?' 2>/dev/null \
  | awk -v want="$voice" '{ sub(/[[:space:]]+[a-z][a-z][-_][A-Za-z0-9]+[[:space:]]+#.*$/, "") } $0 == want { found = 1 } END { exit !found }'; then
  say_args=(-v "$voice" -f -)
fi
write_record "$LAST" "$hash $now" || exit 0
"$say_bin" "${say_args[@]}" <<<"$text" >/dev/null 2>&1 &
speaker=$!
write_record "$SPEAKER" "$speaker $$" || true
# A newer reply that claimed the home while this one started cuts it off here.
is_current || kill "$speaker" 2>/dev/null || true
wait "$speaker" 2>/dev/null || true
read -r old_pid old_parent 2>/dev/null < "$SPEAKER" || true
[ "$old_pid $old_parent" != "$speaker $$" ] || rm -f "$SPEAKER"
exit 0
