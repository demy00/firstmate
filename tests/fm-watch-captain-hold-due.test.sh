#!/usr/bin/env bash
# A captain hold's --until date arriving wakes firstmate once per hold and date.
# Real tasks-axi backlog, the real bin/fm-captain-hold.sh, and the watcher's real
# queue interface; no endpoint, harness process, model call, or remote host.
set -eu

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v tasks-axi >/dev/null 2>&1 || { echo "skip: tasks-axi not found"; exit 0; }

TMP_ROOT=$(fm_test_tmproot fm-watch-captain-hold-due)
export FM_HOME="$TMP_ROOT/home" FM_STATE_OVERRIDE="$TMP_ROOT/home/state"
export FM_CONFIG_OVERRIDE="$TMP_ROOT/home/config" FM_DATA_OVERRIDE="$TMP_ROOT/home/data"
mkdir -p "$FM_STATE_OVERRIDE" "$FM_CONFIG_OVERRIDE" "$FM_DATA_OVERRIDE"
# shellcheck source=bin/fm-watch.sh
. "$ROOT/bin/fm-watch.sh"

HOLD="$ROOT/bin/fm-captain-hold.sh"

reset_case() {
  rm -f -- "$STATE"/* "$STATE"/.[!.]* "$DATA"/*.md
  rm -rf -- "${DATA:?}"/*/
  fm_test_tasks_toml "$FM_HOME/.tasks.toml"
  printf '## In flight\n\n## Queued\n\n## Done\n' > "$DATA/backlog.md"
  CAPTAIN_HOLD_DUE_REASON=
}

count_wakes() {
  if [ -f "$FM_WAKE_QUEUE" ]; then wc -l < "$FM_WAKE_QUEUE" | tr -d ' '; else printf 0; fi
}

hold() {  # <id> [hold args...]
  local id=$1
  shift
  "$HOLD" hold "$id" --reason "question $id" --title "Question $id" --repo x "$@" >/dev/null \
    || fail "could not hold $id"
}

answer() {  # <id> [answer args...]
  local id=$1 file="$TMP_ROOT/decision-$1"
  shift
  printf 'the captain answered %s\n' "$id" > "$file"
  "$HOLD" answer "$id" --decision-file "$file" "$@" >/dev/null || fail "could not answer $id"
}

test_due_today_wakes_once() {
  reset_case
  hold today-q --until 2026-11-14
  captain_hold_due_tick 2026-11-14 || fail "tick failed on a due hold"
  [ "$(count_wakes)" = 1 ] || fail "a hold due today did not queue exactly one wake: $(cat "$FM_WAKE_QUEUE" 2>/dev/null)"
  [ "$CAPTAIN_HOLD_DUE_REASON" = 'check: captain hold today-q recheck due 2026-11-14' ] \
    || fail "unexpected due reason: $CAPTAIN_HOLD_DUE_REASON"
  grep -F 'check: captain hold today-q recheck due 2026-11-14' "$FM_WAKE_QUEUE" >/dev/null \
    || fail "the queued row does not carry the due reason"
  captain_hold_due_tick 2026-11-14 || fail "repeat tick failed"
  captain_hold_due_tick 2026-11-20 || fail "later tick failed"
  [ "$(count_wakes)" = 1 ] || fail "the same hold and date woke again: $(cat "$FM_WAKE_QUEUE")"
  [ -z "$CAPTAIN_HOLD_DUE_REASON" ] || fail "a repeat tick still reported a reason: $CAPTAIN_HOLD_DUE_REASON"
  pass "a hold due today wakes exactly once, and never again for that date"
}

test_past_date_wakes_once() {
  reset_case
  hold past-q --until 2026-11-01
  captain_hold_due_tick 2026-11-14 || fail "tick failed on an overdue hold"
  [ "$(count_wakes)" = 1 ] || fail "a hold whose date already passed did not wake once"
  [ "$CAPTAIN_HOLD_DUE_REASON" = 'check: captain hold past-q recheck due 2026-11-01' ] \
    || fail "unexpected overdue reason: $CAPTAIN_HOLD_DUE_REASON"
  pass "a hold whose date passed while nobody looked wakes once on the next tick"
}

test_future_and_undated_silent() {
  reset_case
  hold future-q --until 2026-12-01
  hold undated-q
  captain_hold_due_tick 2026-11-30 || fail "tick failed with nothing due"
  [ "$(count_wakes)" = 0 ] || fail "a future or undated hold woke: $(cat "$FM_WAKE_QUEUE")"
  [ -z "$CAPTAIN_HOLD_DUE_REASON" ] || fail "nothing due still reported: $CAPTAIN_HOLD_DUE_REASON"
  captain_hold_due_tick 2026-12-01 || fail "tick failed on the arrival day"
  [ "$(count_wakes)" = 1 ] || fail "the future hold did not wake on its date"
  [ "$CAPTAIN_HOLD_DUE_REASON" = 'check: captain hold future-q recheck due 2026-12-01' ] \
    || fail "the arrival wake named the wrong hold: $CAPTAIN_HOLD_DUE_REASON"
  pass "future-dated holds stay silent until their date and undated holds never wake"
}

test_rehold_new_date_wakes_again() {
  reset_case
  hold redate-q --until 2026-11-10
  captain_hold_due_tick 2026-11-10 || fail "first tick failed"
  [ "$(count_wakes)" = 1 ] || fail "the first date did not wake"
  hold redate-q --until 2026-11-20
  captain_hold_due_tick 2026-11-15 || fail "tick between the dates failed"
  [ "$(count_wakes)" = 1 ] || fail "a re-dated hold woke before its new date: $(cat "$FM_WAKE_QUEUE")"
  captain_hold_due_tick 2026-11-20 || fail "tick on the new date failed"
  [ "$(count_wakes)" = 2 ] || fail "the re-dated hold did not wake on its new date"
  [ "$CAPTAIN_HOLD_DUE_REASON" = 'check: captain hold redate-q recheck due 2026-11-20' ] \
    || fail "the second wake did not name the new date: $CAPTAIN_HOLD_DUE_REASON"
  captain_hold_due_tick 2026-11-21 || fail "tick after the new date failed"
  [ "$(count_wakes)" = 2 ] || fail "the new date woke more than once"
  pass "re-holding with a new date wakes again on the new date, once"
}

test_answered_and_released_never_wake() {
  reset_case
  hold closed-q --until 2026-11-01
  answer closed-q
  hold released-q --until 2026-11-01
  answer released-q --release
  hold done-q --until 2026-11-01
  (cd "$FM_HOME" && tasks-axi done done-q --file "$DATA/backlog.md" >/dev/null) \
    || fail "could not close done-q outside the hold owner"
  captain_hold_due_tick 2026-11-14 || fail "tick failed over settled holds"
  [ "$(count_wakes)" = 0 ] || fail "an answered, released, or closed hold woke: $(cat "$FM_WAKE_QUEUE")"
  pass "answered, released, and closed holds never wake on their old date"
}

test_answered_after_wake_stays_silent() {
  reset_case
  hold settle-q --until 2026-11-10
  captain_hold_due_tick 2026-11-10 || fail "tick failed"
  answer settle-q
  captain_hold_due_tick 2026-11-11 || fail "tick after the answer failed"
  [ "$(count_wakes)" = 1 ] || fail "an answer after the due wake produced another wake"
  pass "a hold answered after its due wake stays silent"
}

test_new_hold_lifecycle_same_date_wakes() {
  reset_case
  hold cycle-q --until 2026-11-10
  captain_hold_due_tick 2026-11-10 || fail "first tick failed"
  answer cycle-q --release
  sleep 1
  hold cycle-q --until 2026-11-10
  captain_hold_due_tick 2026-11-11 || fail "tick on the new lifecycle failed"
  [ "$(count_wakes)" = 2 ] || fail "a new hold on the same task and date inherited the old wake"
  pass "a released then re-held call is a new hold and wakes on its own"
}

test_several_due_holds_each_queue() {
  reset_case
  hold a-q --until 2026-11-02
  hold b-q --until 2026-11-03
  captain_hold_due_tick 2026-11-14 || fail "tick failed"
  [ "$(count_wakes)" = 2 ] || fail "two due holds did not queue one row each"
  case "$CAPTAIN_HOLD_DUE_REASON" in
    *'captain hold a-q recheck due 2026-11-02'*'captain hold b-q recheck due 2026-11-03'*) ;;
    *) fail "the wake reason did not name both holds: $CAPTAIN_HOLD_DUE_REASON" ;;
  esac
  pass "several holds due together each queue their own wake"
}

test_unreadable_backlog_stays_silent() {
  reset_case
  hold broken-q --until 2026-11-01
  printf 'backend = "nonesuch"\n' > "$FM_HOME/.tasks.toml"
  captain_hold_due_tick 2026-11-14 || fail "an unreadable backlog failed the tick"
  [ "$(count_wakes)" = 0 ] || fail "an unreadable backlog queued a wake"
  fm_test_tasks_toml "$FM_HOME/.tasks.toml"
  captain_hold_due_tick 2026-11-14 || fail "tick failed once readable again"
  [ "$(count_wakes)" = 1 ] || fail "the due hold did not wake once the backlog became readable"
  pass "an unreadable backlog wakes nothing and records nothing, so the hold wakes once readable"
}

test_watcher_loop() {
  local dir="$TMP_ROOT/watcher-loop" pid i=0 today
  today=$(date -u +%Y-%m-%d)
  mkdir -p "$dir/state" "$dir/config" "$dir/data"
  fm_test_track_watcher_state "$dir/state"
  fm_test_tasks_toml "$dir/.tasks.toml"
  printf '## In flight\n\n## Queued\n\n## Done\n' > "$dir/data/backlog.md"
  FM_HOME="$dir" FM_STATE_OVERRIDE="$dir/state" FM_CONFIG_OVERRIDE="$dir/config" FM_DATA_OVERRIDE="$dir/data" \
    "$HOLD" hold loop-q --reason "loop question" --title "Loop question" --repo x --until "$today" >/dev/null \
    || fail "could not hold loop-q"
  touch "$dir/state/home-summary.json"
  FM_HOME="$dir" FM_STATE_OVERRIDE="$dir/state" FM_CONFIG_OVERRIDE="$dir/config" FM_DATA_OVERRIDE="$dir/data" \
    bash "$ROOT/bin/fm-watch.sh" > "$dir/out" 2> "$dir/err" &
  pid=$!
  while [ "$i" -lt 150 ] && kill -0 "$pid" 2>/dev/null; do sleep 0.1; i=$((i + 1)); done
  if kill -0 "$pid" 2>/dev/null; then
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
    fail "real watcher did not wake on a due captain hold: $(cat "$dir/err")"
  fi
  wait "$pid" || fail "real watcher exited unsuccessfully: $(cat "$dir/err")"
  grep -F "check: captain hold loop-q recheck due $today" "$dir/out" >/dev/null \
    || fail "real watcher did not print the due wake: $(cat "$dir/out")"
  grep -cF "captain hold loop-q recheck due $today" "$dir/state/.wake-queue" | grep -qx 1 \
    || fail "real watcher did not durably queue exactly one due wake"
  pass "the actual watcher wakes and exits on a captain hold whose date arrived"
}

fm_test_run test_due_today_wakes_once test_past_date_wakes_once \
  test_future_and_undated_silent test_rehold_new_date_wakes_again \
  test_answered_and_released_never_wake test_answered_after_wake_stays_silent \
  test_new_hold_lifecycle_same_date_wakes test_several_due_holds_each_queue \
  test_unreadable_backlog_stays_silent test_watcher_loop
