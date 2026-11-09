#!/usr/bin/env bash
# Live guard for the Claude usage-limit declaration (bin/fm-claude-usage.sh):
# the verdict rests on what Claude Code emits - the StopFailure event, its
# `error` kind, and its rendered "resets <time> (<zone>)" text - so it is proven
# against the real installed Claude Code, not a stub of it.
#
# Real fm-spawn writes a worker's hook settings into a fixture worktree, then
# the real `claude -p` runs there against tests/fixtures/claude-usage/limit-api.mjs,
# a local stand-in API that answers the way the API answers a spent claude.ai
# plan window. No model token is spent and no real limit is touched; Claude
# keeps its existing login, whose credential reaches only that local stand-in.
# Asserted: the limit stop declares a usage-limit wait whose `until` is the
# minute after the reset the API published, and the next turn start closes it
# before the repeated stop declares it again.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

fm_live_gate default-on FM_CLAUDE_USAGE_LIVE claude node

# shellcheck source=bin/fm-classify-lib.sh
. "$ROOT/bin/fm-classify-lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-claude-usage-live)
CLAUDE_VERSION=$(claude --version 2>/dev/null | head -1)
API_PID=''
stop_api() { [ -z "$API_PID" ] || kill "$API_PID" 2>/dev/null || true; }
trap 'stop_api; fm_test_cleanup' EXIT

test_real_claude_limit_stop_declares_and_next_turn_closes() {
  local case_dir home proj wt fakebin id=limit-live-1 out reset port_file port i
  local status want line paused resolved
  case_dir="$TMP_ROOT/live"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  fakebin=$(make_spawn_fakebin "$case_dir/fake" claude)
  fm_test_spawn_home "$home" claude
  fm_git_worktree "$proj" "$wt" wt-limit-live
  fm_test_spawn_brief "$home" "$id"
  out=$(fm_test_run_spawn "$home" "$wt" "$fakebin" "$id" "$proj" --mode no-mistakes --yolo off)
  expect_code 0 $? "claude spawn should succeed: $out"
  status="$home/state/$id.status"
  : > "$status"

  # A reset two hours out and deliberately not on a minute boundary.
  reset=$(( $(date +%s) + 7200 + 30 ))
  reset=$(( reset - reset % 60 + 30 ))
  port_file="$case_dir/api.port"
  node "$ROOT/tests/fixtures/claude-usage/limit-api.mjs" "$reset" "$port_file" &
  API_PID=$!
  i=0
  while [ ! -s "$port_file" ] && [ "$i" -lt 50 ]; do
    perl -e 'select(undef, undef, undef, 0.1)'
    i=$((i + 1))
  done
  port=$(cat "$port_file" 2>/dev/null) || fail "the stand-in API did not start"

  run_claude() {
    ( cd "$wt" && env -u FM_HOME ANTHROPIC_BASE_URL="http://127.0.0.1:$port" \
      claude -p --model haiku 'Reply with the single word ok.' </dev/null >/dev/null 2>&1 ) || :
  }

  run_claude
  line=$(last_status_line "$status")
  status_is_usage_reset_wait "$line" \
    || fail "Claude $CLAUDE_VERSION: the real limit stop declared no usage-limit wait (status: $(cat "$status"))"
  assert_contains "$line" "You've hit your" "Claude $CLAUDE_VERSION: the declaration must carry Claude's own limit text"
  want=$(( reset - reset % 60 + 60 ))
  assert_equals "$want" "$(status_paused_until "$line")" \
    "Claude $CLAUDE_VERSION: the declared wait must clear the minute after the published reset"

  run_claude
  paused=$(grep -c '^paused' "$status")
  resolved=$(grep -c '^resolved' "$status")
  assert_equals 2 "$paused" "Claude $CLAUDE_VERSION: the second stop must declare again after the turn start closed the first"
  assert_equals 1 "$resolved" "Claude $CLAUDE_VERSION: the second turn's start must close the first declaration"
  status_is_usage_reset_wait "$(status_declared_wait_line "$status")" \
    || fail "Claude $CLAUDE_VERSION: the repeated stop must leave the wait declared"
  pass "Claude $CLAUDE_VERSION: a real limit stop declares the wait with its reset, and the next turn start closes it"
}

fm_test_run test_real_claude_limit_stop_declares_and_next_turn_closes
