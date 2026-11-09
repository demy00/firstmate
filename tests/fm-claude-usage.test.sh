#!/usr/bin/env bash
# Behavior tests for bin/fm-claude-usage.sh: a Claude worker stopped by an
# account usage limit declares its own wait, with the reset time, through the
# existing `paused:` absorb path, and firstmate can resume it with one command.
#
# Every limit message below is a real one: tests/fixtures/claude-usage/ holds
# the distinct rate_limit texts Claude Code recorded in this machine's own
# transcripts (2.1.288-2.1.318), each with the moment it was recorded, and every
# other API error text those transcripts hold.
# Verdicts are read back through bin/fm-classify-lib.sh, the same reader the
# watcher and daemon use, so a line that only looks right fails here.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"
# shellcheck source=bin/fm-classify-lib.sh
. "$ROOT/bin/fm-classify-lib.sh"
# shellcheck source=bin/fm-busy-lib.sh
. "$ROOT/bin/fm-busy-lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-claude-usage)
USAGE="$ROOT/bin/fm-claude-usage.sh"
FIXTURES="$ROOT/tests/fixtures/claude-usage"

new_state() {  # -> a fresh state dir on stdout
  local dir
  dir=$(mktemp -d "$TMP_ROOT/state.XXXXXX")
  printf '%s\n' "$dir"
}

# A StopFailure payload exactly as Claude Code documents and sends it: the
# error kind plus the rendered error text in last_assistant_message.
stop_failure_payload() {  # <error> <rendered-text>
  jq -cn --arg e "$1" --arg m "$2" \
    '{session_id:"s", transcript_path:"/tmp/t.jsonl", cwd:"/tmp", hook_event_name:"StopFailure", error:$e, last_assistant_message:$m}'
}

utc_epoch() {  # <YYYY-MM-DDTHH:MMZ>
  fm_utc_iso_to_epoch "$1"
}

test_real_session_limit_declares_usage_wait_with_reset() {
  local state line now want
  state=$(new_state)
  # 10:00 in Budapest (CEST) on 2026-09-09, the morning of the second freeze.
  now=$(utc_epoch 2026-09-09T08:00Z)
  stop_failure_payload rate_limit "You've hit your session limit · resets 11:40am (Europe/Budapest)" \
    | FM_CLAUDE_USAGE_NOW=$now "$USAGE" stop-failure "$state" w1
  line=$(last_status_line "$state/w1.status")
  status_is_usage_reset_wait "$line" || fail "a real session-limit stop must declare a usage-limit wait (got: $line)"
  want=$(utc_epoch 2026-09-09T09:41Z)
  # Claude shows the reset floored to the minute (verified live, 2.1.319), so
  # the wait clears in the minute after the one it names.
  assert_equals "$want" "$(status_paused_until "$line")" "the declared wait must clear just after the vendor's own reset time"
  assert_contains "$line" "You've hit your session limit · resets 11:40am (Europe/Budapest)" \
    "the declaration must carry the vendor's reset text verbatim"
  pass "a real session-limit stop declares a usage-limit wait that clears at the published reset"
}

declare_from() {  # <state> <id> <now> <error> <text> -> the status line it left
  stop_failure_payload "$4" "$5" | FM_CLAUDE_USAGE_NOW=$3 "$USAGE" stop-failure "$1" "$2"
  last_status_line "$1/$2.status"
}

test_every_recorded_limit_text_declares_a_bounded_wait() {
  local state when version text now bound line until n=0
  state=$(new_state)
  # Each real text is replayed at the moment Claude recorded it, so its reset
  # must land inside the window the text names: a session or 5-hour limit
  # resets within five hours, a weekly one within seven days.
  while IFS=$'\t' read -r when version text; do
    [ -n "$text" ] || continue
    n=$((n + 1))
    now=$(fm_utc_iso_to_epoch "$when") || fail "fixture row $n has no readable time: $when"
    case "$text" in
      *"weekly limit"*) bound=$((7 * 86400)) ;;
      *) bound=$((5 * 3600 + 60)) ;;
    esac
    line=$(declare_from "$state" "real$n" "$now" rate_limit "$text")
    status_is_usage_reset_wait "$line" || fail "real limit text #$n ($version) did not declare a usage-limit wait: $text"
    until=$(status_paused_until "$line") || fail "real limit text #$n ($version) declared no reset time: $text"
    [ "$until" -gt "$now" ] && [ "$until" -le $((now + bound)) ] \
      || fail "real limit text #$n ($version) declared a reset outside its window ($until vs recorded $now): $text"
    assert_contains "$line" "$text" "real limit text #$n must be carried verbatim"
  done < "$FIXTURES/rate-limit-messages.tsv"
  # Floor: the fixture holds 23 distinct real texts; a misaimed read is red.
  [ "$n" -ge 20 ] || fail "only $n real limit texts were exercised"
  pass "all $n recorded real limit texts declare a usage-limit wait that resets inside the window they name"
}

test_reset_shapes_resolve_to_the_right_instant() {
  local state now line
  state=$(new_state)
  # 23:58 UTC on 2026-10-29 is 00:58 on the 30th in Budapest (CET): "resets 2am"
  # is later that same local night, not 2am on the 29th.
  now=$(utc_epoch 2026-10-29T23:58Z)
  line=$(declare_from "$state" a "$now" rate_limit "You've hit your 5-hour limit · resets 2am (Europe/Budapest)")
  assert_equals "$(utc_epoch 2026-10-30T01:01Z)" "$(status_paused_until "$line")" "a small-hours reset lands on the coming night"
  # 22:12 UTC on 2026-10-11 is 00:12 on the 12th in Budapest (CEST): "12am" is
  # the midnight just passed, so the next one is 24 hours on.
  now=$(utc_epoch 2026-10-11T23:50Z)
  line=$(declare_from "$state" b "$now" rate_limit "You've hit your session limit · resets 12am (Europe/Budapest)")
  assert_equals "$(utc_epoch 2026-10-12T22:01Z)" "$(status_paused_until "$line")" "12am is midnight, rolled forward past now"
  # A weekly reset names its date (the real Casablanca sample is replayed
  # above; Budapest keeps this exact instant independent of host zone data).
  now=$(utc_epoch 2026-10-05T01:17Z)
  line=$(declare_from "$state" c "$now" rate_limit "You've hit your weekly limit · resets Oct 7 at 5pm (Europe/Budapest)")
  assert_equals "$(utc_epoch 2026-10-07T15:01Z)" "$(status_paused_until "$line")" "a dated weekly reset resolves in its own zone"
  pass "small-hours, midnight, and dated weekly resets resolve to the right UTC instant"
}

test_a_reset_minute_already_begun_is_not_pushed_a_day_out() {
  local state now line
  state=$(new_state)
  # Claude shows the reset to the minute. A stop recorded a few seconds into
  # that minute is due now, not at the same time tomorrow or next year.
  now=$(( $(utc_epoch 2026-09-09T09:40Z) + 20 ))
  line=$(declare_from "$state" a "$now" rate_limit "You've hit your session limit · resets 11:40am (Europe/Budapest)")
  assert_equals "$(utc_epoch 2026-09-09T09:41Z)" "$(status_paused_until "$line")" "a just-begun reset minute stays today"
  now=$(( $(utc_epoch 2026-10-07T15:00Z) + 20 ))
  line=$(declare_from "$state" b "$now" rate_limit "You've hit your weekly limit · resets Oct 7 at 5pm (Europe/Budapest)")
  assert_equals "$(utc_epoch 2026-10-07T15:01Z)" "$(status_paused_until "$line")" "a just-begun dated reset stays this year"
  pass "a reset minute that has just begun is declared as due, not rolled a day or a year forward"
}

test_other_api_errors_declare_nothing() {
  local state kind text n=0
  state=$(new_state)
  while IFS=$'\t' read -r kind text; do
    [ -n "$kind" ] || continue
    n=$((n + 1))
    stop_failure_payload "$kind" "$text" \
      | FM_CLAUDE_USAGE_NOW=1794240000 "$USAGE" stop-failure "$state" other
  done < "$FIXTURES/other-api-errors.tsv"
  [ "$n" -ge 5 ] || fail "only $n real non-limit errors were exercised"
  [ ! -e "$state/other.status" ] || fail "a non-limit API error declared a wait: $(cat "$state/other.status")"
  # Negative control on the same path: a limit through the same loop does write.
  stop_failure_payload rate_limit "You've hit your session limit · resets 4:40am (Europe/Budapest)" \
    | FM_CLAUDE_USAGE_NOW=1794240000 "$USAGE" stop-failure "$state" other
  [ -s "$state/other.status" ] || fail "negative control: the limit stop wrote nothing"
  pass "the $n recorded non-limit API errors declare nothing"
}

# Every StopFailure hook command fm-spawn wrote, run the way Claude runs them:
# each one separately, each with the whole payload on stdin.
run_stop_failure_hooks() {  # <settings.json> <payload>
  local cmd n=0
  while IFS= read -r cmd; do
    [ -n "$cmd" ] || continue
    n=$((n + 1))
    printf '%s' "$2" | sh -c "$cmd" || fail "a StopFailure hook command exited nonzero: $cmd"
  done < <(jq -r '.hooks.StopFailure[].hooks[].command' "$1")
  [ "$n" -gt 0 ] || fail "no StopFailure hook command in $1"
}

test_spawned_claude_worker_declares_its_own_limit_stop() {
  local id=limit-cl-1 out settings line state
  spawn_claude_worker spawn "$id"
  state="$SPAWN_HOME/state"
  settings="$SPAWN_WT/.claude/settings.local.json"

  # A non-limit API error leaves the status log exactly as before.
  : > "$state/$id.status"
  run_stop_failure_hooks "$settings" "$(stop_failure_payload server_error "API Error: Connection lost mid-response. The response above may be incomplete.")"
  assert_equals "" "$(cat "$state/$id.status")" "a non-limit API error must not declare a wait"

  run_stop_failure_hooks "$settings" "$(stop_failure_payload rate_limit "You've hit your session limit · resets 4:40am (Europe/Budapest)")"
  line=$(last_status_line "$state/$id.status")
  status_is_usage_reset_wait "$line" || fail "the spawned worker's limit stop did not declare a usage-limit wait (got: $line)"
  status_paused_until "$line" >/dev/null || fail "the spawned worker's declaration carries no reset time: $line"
  out=$(fm_busy_classify tmux fake:w claude "$id" "$state")
  assert_equals "idle claude-hook" "$out" "the limit stop must still close the busy turn"
  pass "a spawned Claude worker declares its own usage-limit stop and still closes its busy turn"
}

run_hooks() {  # <settings.json> <event> <payload>
  local cmd n=0
  while IFS= read -r cmd; do
    [ -n "$cmd" ] || continue
    n=$((n + 1))
    printf '%s' "$3" | sh -c "$cmd" || fail "a $2 hook command exited nonzero: $cmd"
  done < <(jq -r --arg e "$2" '.hooks[$e][].hooks[].command' "$1")
  [ "$n" -gt 0 ] || fail "no $2 hook command in $1"
}

# A real fm-spawn of a Claude worker into a fixture home with a fake pane.
# Sets SPAWN_HOME, SPAWN_WT, and SPAWN_FAKEBIN.
spawn_claude_worker() {  # <case-name> <id>...
  local case_dir=$TMP_ROOT/$1 proj id out
  shift
  proj="$case_dir/project"
  SPAWN_HOME="$case_dir/home"
  SPAWN_WT="$case_dir/wt"
  SPAWN_FAKEBIN=$(make_spawn_fakebin "$case_dir/fake" claude)
  fm_test_spawn_home "$SPAWN_HOME" claude
  fm_git_worktree "$proj" "$SPAWN_WT" "wt-$(basename "$case_dir")"
  for id in "$@"; do
    fm_test_spawn_brief "$SPAWN_HOME" "$id"
    out=$(fm_test_run_spawn "$SPAWN_HOME" "$SPAWN_WT" "$SPAWN_FAKEBIN" "$id" "$proj" --mode no-mistakes --yolo off)
    expect_code 0 $? "claude spawn of $id should succeed: $out"
  done
}

# Run fm-claude-usage.sh as firstmate does, against the spawned fixture home.
usage_as_firstmate() {  # <now> <args...>
  local now=$1
  shift
  FM_CLAUDE_USAGE_NOW=$now FM_HOME="$SPAWN_HOME" FM_STATE_OVERRIDE="$SPAWN_HOME/state" \
    FM_DATA_OVERRIDE="$SPAWN_HOME/data" FM_CONFIG_OVERRIDE="$SPAWN_HOME/config" \
    TMUX="${TMUX:-fake,1,0}" PATH="$SPAWN_FAKEBIN:$PATH" "$USAGE" "$@" 2>&1
}

inbox_bodies() {  # <state> <id> -> every steering record body for the task
  cat "$1/$2.inbox"/*.msg 2>/dev/null
}

test_a_new_turn_after_the_stop_closes_the_declared_wait() {
  local id=limit-ts-1 state settings before line prompt
  spawn_claude_worker turn-start "$id"
  state="$SPAWN_HOME/state"
  settings="$SPAWN_WT/.claude/settings.local.json"
  prompt='{"hook_event_name":"UserPromptSubmit","prompt":"x"}'
  : > "$state/$id.status"

  # An ordinary turn start with no limit declared writes nothing.
  run_hooks "$settings" UserPromptSubmit "$prompt"
  assert_equals "" "$(cat "$state/$id.status")" "a turn start with no declared limit must not touch the status log"

  # Claude Code continues a limited session on its own at the reset (verified
  # live, 2.1.319): that new turn closes the wait the stop declared.
  run_hooks "$settings" StopFailure "$(stop_failure_payload rate_limit "You've hit your 5-hour limit · resets 2:10pm (Europe/Budapest)")"
  status_is_usage_reset_wait "$(status_declared_wait_line "$state/$id.status")" || fail "the stop must declare the wait first"
  run_hooks "$settings" UserPromptSubmit "$prompt"
  assert_equals "" "$(status_declared_wait_line "$state/$id.status")" "the continued turn must close the declared wait"

  # A usage-limit pause someone else declared (an away session holding the
  # fleet) is theirs to close, not this hook's.
  printf 'paused: usage limit - held at 95%% by the away session until 2026-11-10T08:00Z\n' >> "$state/$id.status"
  before=$(cat "$state/$id.status")
  run_hooks "$settings" UserPromptSubmit "$prompt"
  assert_equals "$before" "$(cat "$state/$id.status")" "a pause this script did not declare must be left alone"
  line=$(status_declared_wait_line "$state/$id.status")
  status_is_usage_reset_wait "$line" || fail "the away session's pause must still stand"
  pass "a new turn after a usage-limit stop closes the wait the stop declared, and nothing else"
}

test_resume_steers_a_worker_whose_limit_has_reset_and_closes_the_wait() {
  local id=limit-rs-1 state stopped reset out rc
  spawn_claude_worker resume "$id"
  state="$SPAWN_HOME/state"
  stopped=$(utc_epoch 2026-09-09T08:00Z)
  reset=$(utc_epoch 2026-09-09T09:41Z)
  declare_from "$state" "$id" "$stopped" rate_limit "You've hit your session limit · resets 11:40am (Europe/Budapest)" >/dev/null

  # Before the reset the worker cannot run, so a resume is refused and sends nothing.
  out=$(usage_as_firstmate $((reset - 60)) resume "$id")
  rc=$?
  [ "$rc" -ne 0 ] || fail "resume before the reset must refuse: $out"
  assert_contains "$out" "2026-09-09T09:41Z" "the refusal must say when the limit resets"
  assert_equals "" "$(inbox_bodies "$state" "$id")" "a refused resume must send nothing"

  out=$(usage_as_firstmate $((reset + 60)) resume "$id")
  expect_code 0 $? "resume after the reset should succeed: $out"
  assert_contains "$(inbox_bodies "$state" "$id")" "usage limit" "the worker must be told the limit has reset"
  assert_contains "$(inbox_bodies "$state" "$id")" "where you stopped" "the worker must be told to continue where it stopped"
  assert_equals "" "$(status_declared_wait_line "$state/$id.status")" "the resume must close the declared wait"
  pass "resume refuses before the reset, and after it steers the worker on and closes its declared wait"
}

test_resume_due_brings_back_every_worker_the_reset_freed_and_only_those() {
  local state stopped reset out
  spawn_claude_worker resume-due fz-a fz-b fz-c fz-d
  state="$SPAWN_HOME/state"
  stopped=$(utc_epoch 2026-09-09T08:00Z)
  reset=$(utc_epoch 2026-09-09T09:41Z)
  # One freeze stops three workers in the same minute; a fourth waits on its weekly limit.
  declare_from "$state" fz-a "$stopped" rate_limit "You've hit your session limit · resets 11:40am (Europe/Budapest)" >/dev/null
  declare_from "$state" fz-b "$stopped" rate_limit "You've hit your session limit · resets 11:40am (Europe/Budapest)" >/dev/null
  declare_from "$state" fz-c "$stopped" rate_limit "You've hit your session limit · resets 11:40am (Europe/Budapest)" >/dev/null
  declare_from "$state" fz-d "$stopped" rate_limit "You've hit your weekly limit · resets Sep 12 at 7pm (Europe/Budapest)" >/dev/null

  out=$(usage_as_firstmate $((reset + 60)) resume --due)
  expect_code 0 $? "resume --due should succeed: $out"
  assert_contains "$(inbox_bodies "$state" fz-a)" "usage limit" "fz-a was freed by the reset"
  assert_contains "$(inbox_bodies "$state" fz-b)" "usage limit" "fz-b was freed by the reset"
  assert_contains "$(inbox_bodies "$state" fz-c)" "usage limit" "fz-c was freed by the reset"
  assert_equals "" "$(inbox_bodies "$state" fz-d)" "fz-d's weekly limit has not reset and must not be steered"
  status_is_usage_reset_wait "$(status_declared_wait_line "$state/fz-d.status")" \
    || fail "fz-d must still be declared as waiting on its limit"
  pass "resume --due steers every worker whose limit has reset in one call, and leaves the rest waiting"
}

# A bin dir holding the real scripts and a stand-in fm-send.sh that runs
# <steer-body> as the steered worker, so a test controls what the worker's next
# turn does while the steer is being delivered.
bin_with_send() {  # <dir> <steer-body>
  local dir=$1 f
  mkdir -p "$dir"
  for f in "$ROOT"/bin/*; do
    [ "${f##*/}" = fm-send.sh ] || ln -s "$f" "$dir/${f##*/}"
  done
  printf '#!/usr/bin/env bash\n%s\n' "$2" > "$dir/fm-send.sh"
  chmod +x "$dir/fm-send.sh"
}

test_resume_keeps_a_limit_the_steered_turn_hits_and_restores_the_wait_on_a_failed_steer() {
  local state stopped reset bin out line declared
  state=$(new_state)
  stopped=$(utc_epoch 2026-09-09T08:00Z)
  reset=$(utc_epoch 2026-09-09T09:41Z)

  # The session window resets, the steered turn hits the weekly limit at once,
  # and its StopFailure fires before fm-send.sh returns.
  declare_from "$state" w "$stopped" rate_limit "You've hit your session limit · resets 11:40am (Europe/Budapest)" >/dev/null
  bin="$TMP_ROOT/bin-relimit"
  stop_failure_payload rate_limit "You've hit your weekly limit · resets Sep 12 at 7pm (Europe/Budapest)" > "$TMP_ROOT/relimit.json"
  bin_with_send "$bin" "FM_CLAUDE_USAGE_NOW=$((reset + 61)) $(printf '%q stop-failure %q w < %q' "$bin/fm-claude-usage.sh" "$state" "$TMP_ROOT/relimit.json")"
  out=$(FM_HOME="$TMP_ROOT/home" FM_STATE_OVERRIDE="$state" FM_CLAUDE_USAGE_NOW=$((reset + 60)) "$bin/fm-claude-usage.sh" resume w 2>&1)
  expect_code 0 $? "resume after the reset should succeed: $out"
  line=$(status_declared_wait_line "$state/w.status")
  status_is_usage_reset_wait "$line" || fail "the limit the steered turn hit must stay declared (got: $(cat "$state/w.status"))"
  assert_contains "$line" "weekly limit" "the standing wait must be the new weekly limit"

  # A steer that is not delivered leaves the worker idle on its limit, so the
  # wait it declared stands exactly as it was.
  declare_from "$state" f "$stopped" rate_limit "You've hit your session limit · resets 11:40am (Europe/Budapest)" >/dev/null
  declared=$(status_declared_wait_line "$state/f.status")
  bin="$TMP_ROOT/bin-undelivered"
  bin_with_send "$bin" 'exit 1'
  if out=$(FM_HOME="$TMP_ROOT/home" FM_STATE_OVERRIDE="$state" FM_CLAUDE_USAGE_NOW=$((reset + 60)) "$bin/fm-claude-usage.sh" resume f 2>&1); then
    fail "an undelivered resume must fail: $out"
  fi
  assert_contains "$out" "failed f" "the failure must be reported"
  assert_equals "$declared" "$(status_declared_wait_line "$state/f.status")" "an undelivered resume must leave the declared wait as it was"
  pass "resume keeps a limit the steered turn hits declared, and an undelivered steer leaves the wait declared"
}

fm_test_run \
  test_real_session_limit_declares_usage_wait_with_reset \
  test_every_recorded_limit_text_declares_a_bounded_wait \
  test_reset_shapes_resolve_to_the_right_instant \
  test_a_reset_minute_already_begun_is_not_pushed_a_day_out \
  test_other_api_errors_declare_nothing \
  test_spawned_claude_worker_declares_its_own_limit_stop \
  test_a_new_turn_after_the_stop_closes_the_declared_wait \
  test_resume_steers_a_worker_whose_limit_has_reset_and_closes_the_wait \
  test_resume_due_brings_back_every_worker_the_reset_freed_and_only_those \
  test_resume_keeps_a_limit_the_steered_turn_hits_and_restores_the_wait_on_a_failed_steer
