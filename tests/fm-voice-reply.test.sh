#!/usr/bin/env bash
# Behavior tests for the opt-in Claude Stop hook that speaks a reply's 🔊 line
# on the Mac through a fake say.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

HOOK="$ROOT/bin/fm-voice-reply.sh"
TMP_ROOT=$(fm_test_tmproot fm-voice-reply)
PRIMARY="$TMP_ROOT/primary"
FAKEBIN="$TMP_ROOT/fakebin"
OUT="$TMP_ROOT/out"
ERR="$TMP_ROOT/err"

mkdir -p "$PRIMARY/bin" "$PRIMARY/state" "$FAKEBIN"
printf '# fixture\n' > "$PRIMARY/AGENTS.md"
git -C "$PRIMARY" init -q
git -C "$PRIMARY" config user.name fixture
git -C "$PRIMARY" config user.email fixture@example.test
git -C "$PRIMARY" config commit.gpgsign false

# The fake say lists two installed voices for `say -v ?`. Otherwise it records
# one call as call.<n>.args (one argument per line) and call.<n>.text (stdin),
# then sleeps FAKE_SAY_SLEEP seconds; a TERM during that sleep is recorded as
# call.<n>.killed.
cat > "$FAKEBIN/say" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = -v ] && [ "${2:-}" = '?' ]; then
  printf '%s\n' 'Samantha            en_US    # Hello, my name is Samantha.' \
    'Zoe (Premium)       en_US    # Hello, my name is Zoe.'
  exit 0
fi
n=$(find "$FAKE_SAY_LOG" -name 'call.*.args' | wc -l | tr -d ' ')
n=$((n + 1))
printf '%s\n' "$@" > "$FAKE_SAY_LOG/call.$n.args"
cat > "$FAKE_SAY_LOG/call.$n.text"
trap 'touch "$FAKE_SAY_LOG/call.$n.killed"; exit 143' TERM
if [ -n "${FAKE_SAY_SLEEP:-}" ]; then
  sleep "$FAKE_SAY_SLEEP" &
  wait $!
fi
exit 0
EOF
chmod +x "$FAKEBIN/say"

prepare_case() {
  CASE_DIR="$TMP_ROOT/cases/$1"
  CASE_STATE="$CASE_DIR/state"
  CASE_CONFIG="$CASE_DIR/config"
  CASE_LOG="$CASE_DIR/say"
  mkdir -p "$CASE_STATE" "$CASE_CONFIG" "$CASE_LOG"
}

# invoke_hook <root> [env assignments...]
# The hook payload is on stdin. The exit status is the hook's.
invoke_hook() {
  local root=$1
  shift
  : > "$OUT"
  : > "$ERR"
  env -u GROK_AGENT -u GROK_HOOK_EVENT -u GROK_HOOK_NAME -u GROK_SESSION_ID \
    -u GROK_WORKSPACE_ROOT \
    FM_ROOT_OVERRIDE="$root" FM_HOME="$root" \
    FM_STATE_OVERRIDE="$CASE_STATE" FM_CONFIG_OVERRIDE="$CASE_CONFIG" \
    FM_VOICE_REPLIES_SAY="$FAKEBIN/say" FAKE_SAY_LOG="$CASE_LOG" \
    FM_VOICE_REPLIES_SETTLE=0 \
    "$@" \
    "$HOOK" >"$OUT" 2>"$ERR"
}

# payload <reply text>
payload() {
  jq -nc --arg msg "$1" \
    '{session_id:"s1",hook_event_name:"Stop",stop_hook_active:false,last_assistant_message:$msg}'
}

say_calls() {
  find "$CASE_LOG" -name 'call.*.args' | wc -l | tr -d ' '
}

assert_silent_hook() {
  local label=$1
  [ ! -s "$OUT" ] || fail "$label wrote stdout: $(cat "$OUT")"
  [ ! -s "$ERR" ] || fail "$label wrote stderr: $(cat "$ERR")"
}

assert_not_spoken() {
  local label=$1 calls
  calls=$(say_calls)
  [ "$calls" -eq 0 ] || fail "$label spoke $calls time(s): $(cat "$CASE_LOG"/call.*.text)"
}

# assert_spoken <label> <call number> <expected text>
assert_spoken() {
  local label=$1 n=$2 want=$3 got
  [ -f "$CASE_LOG/call.$n.text" ] || fail "$label did not speak call $n (calls: $(say_calls)) $(cat "$ERR")"
  got=$(cat "$CASE_LOG/call.$n.text")
  [ "$got" = "$want" ] || fail "$label spoke '$got', expected '$want'"
}

test_mac_mode_speaks_the_marked_line() {
  local rc=0 reply
  prepare_case speaks
  printf 'mode=mac\n' > "$CASE_CONFIG/voice-replies"
  reply=$(printf '%s\n' 'Captain, the fix is ready: https://example.test/pr/1' '' \
    '🔊 The login fix is ready, and I recommend merging it.')
  payload "$reply" | invoke_hook "$PRIMARY" || rc=$?
  [ "$rc" -eq 0 ] || fail "speaking reply must exit 0, got $rc: $(cat "$ERR")"
  assert_silent_hook "speaking reply"
  assert_spoken "speaking reply" 1 'The login fix is ready, and I recommend merging it.'
  [ "$(say_calls)" -eq 1 ] || fail "speaking reply spoke $(say_calls) times"
  pass "mac mode speaks only the 🔊 line, without the marker, and prints nothing"
}

test_last_marked_line_wins_and_markdown_is_dropped() {
  local rc=0 reply
  prepare_case markdown
  printf 'mode=mac\n' > "$CASE_CONFIG/voice-replies"
  # shellcheck disable=SC2016 # The backticks are literal Markdown in the reply.
  reply=$(printf '%s\n' '🔊 An earlier line.' 'Body text with a 🔊 in the middle.' \
    '> **🔊️ The `build` is green, and nothing is needed from you.**  ')
  payload "$reply" | invoke_hook "$PRIMARY" || rc=$?
  [ "$rc" -eq 0 ] || fail "markdown reply must exit 0, got $rc: $(cat "$ERR")"
  assert_spoken "markdown reply" 1 'The build is green, and nothing is needed from you.'
  [ "$(say_calls)" -eq 1 ] || fail "markdown reply spoke $(say_calls) times"

  prepare_case empty-marker
  printf 'mode=mac\n' > "$CASE_CONFIG/voice-replies"
  payload "$(printf '%s\n' 'Text.' '🔊   ')" | invoke_hook "$PRIMARY" || rc=$?
  assert_not_spoken "an empty marked line"
  pass "the last line that starts with 🔊 is spoken, after a quote or bold mark, without its variation selector or Markdown, and an empty one is not"
}

test_quiet_hours_silence_the_speaker() {
  local rc=0 clock
  for clock in 23:30 22:00 00:10 06:59; do
    prepare_case "quiet-$clock"
    printf '%s\n' 'mode=mac' 'quiet=22:00-07:00' > "$CASE_CONFIG/voice-replies"
    payload '🔊 Quiet please.' | invoke_hook "$PRIMARY" FM_VOICE_REPLIES_CLOCK="$clock" || rc=$?
    [ "$rc" -eq 0 ] || fail "quiet hours at $clock must exit 0, got $rc"
    assert_silent_hook "quiet hours at $clock"
    assert_not_spoken "quiet hours at $clock"
  done
  for clock in 07:00 12:00 21:59; do
    prepare_case "awake-$clock"
    printf '%s\n' 'mode=mac' 'quiet=22:00-07:00' > "$CASE_CONFIG/voice-replies"
    payload '🔊 Awake now.' | invoke_hook "$PRIMARY" FM_VOICE_REPLIES_CLOCK="$clock" || rc=$?
    assert_spoken "outside quiet hours at $clock" 1 'Awake now.'
  done
  prepare_case quiet-daytime
  printf '%s\n' 'mode=mac' 'quiet=13:00-14:00' > "$CASE_CONFIG/voice-replies"
  payload '🔊 Lunch.' | invoke_hook "$PRIMARY" FM_VOICE_REPLIES_CLOCK=13:30 || rc=$?
  assert_not_spoken "a same-day quiet window"
  prepare_case quiet-unusable
  printf '%s\n' 'mode=mac' 'quiet=late' > "$CASE_CONFIG/voice-replies"
  payload '🔊 Still spoken.' | invoke_hook "$PRIMARY" FM_VOICE_REPLIES_CLOCK=23:30 || rc=$?
  assert_spoken "an unusable quiet line" 1 'Still spoken.'
  pass "quiet hours silence the speaker across midnight and within a day, and an unusable quiet line is ignored"
}

test_voice_line_picks_an_installed_voice() {
  local rc=0
  prepare_case voice
  printf '%s\n' 'mode=mac' 'voice=Zoe (Premium)' > "$CASE_CONFIG/voice-replies"
  payload '🔊 Hello.' | invoke_hook "$PRIMARY" || rc=$?
  assert_spoken "an installed voice" 1 'Hello.'
  [ "$(sed -n 1,2p "$CASE_LOG/call.1.args" | paste -sd'|' -)" = '-v|Zoe (Premium)' ] \
    || fail "an installed voice was not passed to say: $(cat "$CASE_LOG/call.1.args")"

  prepare_case voice-missing
  printf '%s\n' 'mode=mac' 'voice=Nobody' > "$CASE_CONFIG/voice-replies"
  payload '🔊 Hello anyway.' | invoke_hook "$PRIMARY" || rc=$?
  assert_spoken "a missing voice" 1 'Hello anyway.'
  if grep -qx -- -v "$CASE_LOG/call.1.args"; then
    fail "a missing voice was still passed to say: $(cat "$CASE_LOG/call.1.args")"
  fi
  pass "a voice line uses that voice when it is installed and the default voice when it is not"
}

test_only_mac_mode_speaks() {
  local rc=0 mode
  prepare_case absent
  payload '🔊 Nobody turned me on.' | invoke_hook "$PRIMARY" || rc=$?
  [ "$rc" -eq 0 ] || fail "absent config must exit 0, got $rc"
  assert_silent_hook "absent config"
  assert_not_spoken "absent config"
  [ -z "$(ls -A "$CASE_STATE")" ] || fail "absent config wrote state: $(ls -A "$CASE_STATE")"

  for mode in off phone auto both MAC ''; do
    prepare_case "mode-${mode:-empty}"
    printf '# a comment\nmode=%s\n' "$mode" > "$CASE_CONFIG/voice-replies"
    payload '🔊 Not in this mode.' | invoke_hook "$PRIMARY" || rc=$?
    [ "$rc" -eq 0 ] || fail "mode '$mode' must exit 0, got $rc"
    assert_silent_hook "mode '$mode'"
    assert_not_spoken "mode '$mode'"
  done

  prepare_case mode-padded
  printf 'mode=off\r\n  mode = mac \r\n' > "$CASE_CONFIG/voice-replies"
  payload '🔊 Padded but on.' | invoke_hook "$PRIMARY" || rc=$?
  assert_spoken "a padded later mode line" 1 'Padded but on.'

  prepare_case no-line
  printf 'mode=mac\n' > "$CASE_CONFIG/voice-replies"
  payload 'A reply with no line for the ear.' | invoke_hook "$PRIMARY" || rc=$?
  assert_not_spoken "a reply with no marked line"
  pass "only mode=mac speaks: an absent file, off, the reserved phone and auto values, and a reply with no 🔊 line stay silent"
}

test_crew_worktree_never_speaks() {
  local rc=0 child="$TMP_ROOT/child"
  git -C "$PRIMARY" commit -q --allow-empty -m init
  git -C "$PRIMARY" worktree add -q -b fixture-child "$child"
  mkdir -p "$child/state" "$child/bin"
  printf '# fixture\n' > "$child/AGENTS.md"
  prepare_case crew
  printf 'mode=mac\n' > "$CASE_CONFIG/voice-replies"
  CASE_STATE="$child/state"
  payload '🔊 A worker must not speak.' | invoke_hook "$child" || rc=$?
  [ "$rc" -eq 0 ] || fail "a crew worktree must exit 0, got $rc"
  assert_silent_hook "crew worktree"
  assert_not_spoken "crew worktree"
  pass "a linked crew worktree never speaks, even with the file turned on"
}

test_secondmate_home_speaks_only_when_its_own_file_says_so() {
  local rc=0 second="$TMP_ROOT/second"
  git -C "$PRIMARY" worktree add -q -b fixture-second "$second"
  mkdir -p "$second/state" "$second/bin" "$second/config"
  printf '# fixture\n' > "$second/AGENTS.md"
  printf 'sm-fixture\n' > "$second/.fm-secondmate-home"
  prepare_case secondmate-off
  CASE_STATE="$second/state" CASE_CONFIG="$second/config"
  payload '🔊 Not configured here.' | invoke_hook "$second" || rc=$?
  assert_not_spoken "a secondmate home without the file"

  printf 'mode=mac\n' > "$second/config/voice-replies"
  payload '🔊 The life mate speaks.' | invoke_hook "$second" || rc=$?
  [ "$rc" -eq 0 ] || fail "a configured secondmate home must exit 0, got $rc"
  assert_spoken "a configured secondmate home" 1 'The life mate speaks.'
  pass "a marked secondmate home stays silent until its own config/voice-replies turns it on"
}

test_foreign_and_bad_payloads_are_silent() {
  local rc=0 input
  prepare_case foreign
  printf 'mode=mac\n' > "$CASE_CONFIG/voice-replies"
  payload '🔊 Grok must not speak.' | invoke_hook "$PRIMARY" GROK_HOOK_EVENT=Stop || rc=$?
  [ "$rc" -eq 0 ] || fail "a grok stop must exit 0, got $rc"
  assert_not_spoken "a grok stop"
  jq -nc '{cursor_version:"1.0",last_assistant_message:"🔊 Cursor must not speak."}' \
    | invoke_hook "$PRIMARY" || rc=$?
  [ "$rc" -eq 0 ] || fail "a cursor stop must exit 0, got $rc"
  assert_not_spoken "a cursor stop"
  for input in 'not json' '' '{"last_assistant_message":42}' '[]'; do
    printf '%s' "$input" | invoke_hook "$PRIMARY" || rc=$?
    [ "$rc" -eq 0 ] || fail "payload '$input' must exit 0, got $rc"
    assert_silent_hook "payload '$input'"
  done
  assert_not_spoken "bad payloads"
  pass "Grok and Cursor stops, and unreadable payloads, are silent and exit 0"
}

# start_hook_bg <tag> [env assignments...]: run one hook in the background on
# the payload in $CASE_DIR/<tag>.json, with its own output files; sets BG_PID.
# The redirection is inside, because a background job's stdin is /dev/null.
start_hook_bg() {
  local tag=$1
  shift
  env -u GROK_AGENT -u GROK_HOOK_EVENT -u GROK_HOOK_NAME -u GROK_SESSION_ID \
    -u GROK_WORKSPACE_ROOT \
    FM_ROOT_OVERRIDE="$PRIMARY" FM_HOME="$PRIMARY" \
    FM_STATE_OVERRIDE="$CASE_STATE" FM_CONFIG_OVERRIDE="$CASE_CONFIG" \
    FM_VOICE_REPLIES_SAY="$FAKEBIN/say" FAKE_SAY_LOG="$CASE_LOG" \
    FM_VOICE_REPLIES_SETTLE=0 \
    "$@" \
    "$HOOK" <"$CASE_DIR/$tag.json" >"$CASE_DIR/out.$tag" 2>"$CASE_DIR/err.$tag" &
  BG_PID=$!
}

# wait_for <path> <tenths of a second>
wait_for() {
  local path=$1 limit=$2 i=0
  while [ ! -e "$path" ] && [ "$i" -lt "$limit" ]; do
    sleep 0.1
    i=$((i + 1))
  done
  [ -e "$path" ]
}

test_newer_reply_supersedes_one_still_settling() {
  local first
  prepare_case settling
  printf 'mode=mac\n' > "$CASE_CONFIG/voice-replies"
  payload '🔊 The old answer.' > "$CASE_DIR/first.json"
  start_hook_bg first FM_VOICE_REPLIES_SETTLE=2
  first=$BG_PID
  sleep 0.5
  payload '🔊 The newer answer.' | invoke_hook "$PRIMARY"
  wait "$first" || fail "the superseded hook did not exit 0"
  [ ! -s "$CASE_DIR/out.first" ] && [ ! -s "$CASE_DIR/err.first" ] \
    || fail "the superseded hook printed output"
  assert_spoken "the newer reply" 1 'The newer answer.'
  [ "$(say_calls)" -eq 1 ] || fail "the superseded reply was spoken too: $(cat "$CASE_LOG"/call.*.text)"
  pass "a reply superseded while it settles is never spoken"
}

test_newer_reply_cuts_off_one_still_speaking() {
  local first
  prepare_case speaking
  printf 'mode=mac\n' > "$CASE_CONFIG/voice-replies"
  payload '🔊 A long old answer.' > "$CASE_DIR/first.json"
  start_hook_bg first FAKE_SAY_SLEEP=30
  first=$BG_PID
  wait_for "$CASE_LOG/call.1.text" 50 || fail "the first reply never started speaking"
  payload '🔊 The newer answer.' | invoke_hook "$PRIMARY"
  wait_for "$CASE_LOG/call.1.killed" 50 || fail "the older speech was not cut off"
  wait "$first" || fail "the cut-off hook did not exit 0"
  assert_spoken "the newer reply" 2 'The newer answer.'
  [ ! -e "$CASE_LOG/call.2.killed" ] || fail "the newer speech was cut off"
  pass "a newer reply cuts off an older one that is still speaking"
}

test_repeat_line_is_spoken_once_and_text_is_never_stored() {
  local now=1800000000
  prepare_case repeat
  printf 'mode=mac\n' > "$CASE_CONFIG/voice-replies"
  payload '🔊 Same words.' | invoke_hook "$PRIMARY" FM_VOICE_REPLIES_NOW=$now
  payload '🔊 Same words.' | invoke_hook "$PRIMARY" FM_VOICE_REPLIES_NOW=$((now + 30))
  [ "$(say_calls)" -eq 1 ] || fail "a repeated line was spoken $(say_calls) times"
  payload '🔊 Different words.' | invoke_hook "$PRIMARY" FM_VOICE_REPLIES_NOW=$((now + 40))
  assert_spoken "a different line" 2 'Different words.'
  payload '🔊 Same words.' | invoke_hook "$PRIMARY" FM_VOICE_REPLIES_NOW=$((now + 50))
  assert_spoken "an earlier line after a different one" 3 'Same words.'
  payload '🔊 Same words.' | invoke_hook "$PRIMARY" FM_VOICE_REPLIES_NOW=$((now + 300))
  assert_spoken "a repeated line after the window" 4 'Same words.'
  [ -n "$(ls -A "$CASE_STATE")" ] || fail "the hook kept no record, so this check saw nothing"
  if grep -rq -e 'Same words' -e 'Different words' "$CASE_STATE"; then
    fail "spoken text was written to state: $(grep -rl -e 'Same words' -e 'Different words' "$CASE_STATE")"
  fi
  pass "the same line twice in a row within two minutes is spoken once, and no spoken text is written to state"
}

# The tracked registration is exercised by running its exact command string in
# a fixture home that carries copies of the hook and its library.
test_tracked_stop_registration_is_async_and_inert_until_configured() {
  local entries command rc=0 home="$TMP_ROOT/registered"
  entries=$(jq -c '[.hooks.Stop[].hooks[] | select(.command | contains("/bin/fm-voice-reply.sh"))]' \
    "$ROOT/.claude/settings.json") || fail "tracked Stop hooks could not be read"
  [ "$(jq length <<<"$entries")" -eq 1 ] || fail "expected one Stop registration for fm-voice-reply.sh: $entries"
  jq -e '.[0].async == true and (.[0].asyncRewake | not)' <<<"$entries" >/dev/null \
    || fail "the Stop registration must run in the background without rewaking: $entries"
  command=$(jq -r '.[0].command' <<<"$entries")

  mkdir -p "$home/bin" "$home/state"
  printf '# fixture\n' > "$home/AGENTS.md"
  git -C "$home" init -q
  cp "$HOOK" "$ROOT/bin/fm-primary-scope-lib.sh" "$home/bin/"
  CASE_DIR="$TMP_ROOT/cases/registered" CASE_LOG="$TMP_ROOT/cases/registered/say"
  mkdir -p "$CASE_LOG"
  run_registered() {
    env -u FM_HOME -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_CONFIG_OVERRIDE \
      -u GROK_AGENT -u GROK_HOOK_EVENT \
      CLAUDE_PROJECT_DIR="$home" FM_VOICE_REPLIES_SAY="$FAKEBIN/say" FAKE_SAY_LOG="$CASE_LOG" \
      FM_VOICE_REPLIES_SETTLE=0 "$@" bash -c "$command" >"$OUT" 2>"$ERR"
  }
  payload '🔊 Off by default.' | run_registered || rc=$?
  [ "$rc" -eq 0 ] || fail "the unconfigured registration must exit 0, got $rc"
  assert_silent_hook "the unconfigured registration"
  assert_not_spoken "the unconfigured registration"

  mkdir -p "$home/config"
  printf 'mode=mac\n' > "$home/config/voice-replies"
  payload '🔊 Grok stays quiet.' | run_registered GROK_AGENT=1 || rc=$?
  assert_not_spoken "the registration under grok"
  payload '🔊 Now it speaks.' | run_registered || rc=$?
  [ "$rc" -eq 0 ] || fail "the configured registration must exit 0, got $rc: $(cat "$ERR")"
  assert_silent_hook "the configured registration"
  assert_spoken "the configured registration" 1 'Now it speaks.'
  pass "the tracked Stop registration runs in the background, stays silent until the home's config/voice-replies turns it on, and is inert under grok"
}

fm_test_run \
  test_mac_mode_speaks_the_marked_line \
  test_tracked_stop_registration_is_async_and_inert_until_configured \
  test_newer_reply_supersedes_one_still_settling \
  test_newer_reply_cuts_off_one_still_speaking \
  test_repeat_line_is_spoken_once_and_text_is_never_stored \
  test_only_mac_mode_speaks \
  test_crew_worktree_never_speaks \
  test_secondmate_home_speaks_only_when_its_own_file_says_so \
  test_foreign_and_bad_payloads_are_silent \
  test_last_marked_line_wins_and_markdown_is_dropped \
  test_quiet_hours_silence_the_speaker \
  test_voice_line_picks_an_installed_voice
