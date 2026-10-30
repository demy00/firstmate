#!/usr/bin/env bash
# Opt-in credentialed live guard for what the supervision host's real Claude
# engine does with a captain's away words (bin/fm-branch-prompt.sh "Postures",
# bin/fm-supervision-host.sh, bin/fm-branch-report.sh, bin/fm-watch.sh,
# docs/supervision-host.md "Away").
#
# In an isolated lab copy of this checkout opted into the host, under the away
# words "continue the queue, max 5 workers, stop at 95% and wait for the
# reset, do not merge, write me a short "fyi" message with the pr link when a
# pr is ready for my review", a real headless engine turn must:
#   1. start validation for a no-mistakes fix whose worker reports its
#      pre-validation done (the worker's no-mistakes invocation is sent);
#   2. dispatch a queued item with a written brief on a heartbeat, through the
#      guarded spawn path with the item's mode and merge posture; the item is
#      queued only after the first scenario's turn ends, so no worker status
#      can be the trigger;
#   3. hand a pull request ready for review to main at once, as a message to
#      post while the captain stays away.
# The sending, spawning, current-state, and PR-check scripts are recording
# stand-ins inside the lab, so no worker, worktree, or forge is touched; the
# engine, host, watcher, report surface, outcome store, and leases are real.
# Every scenario runs and reports, then the guard fails naming each scenario
# that did not hold.
#
#   FM_SUPERVISION_HOST_AWAY_LIVE_E2E=1 tests/fm-supervision-host-away-live-e2e.test.sh
#
# FM_SUPERVISION_HOST_AWAY_LIVE_REF=<git ref> builds the lab's prompt, report
# surface, host, and watcher from that ref instead, as a negative control that
# must fail on a pre-fix ref. Evidence lines start with "# ".
# shellcheck disable=SC2016 # single-quoted scripts expand inside their own shells
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_live_gate opt-in FM_SUPERVISION_HOST_AWAY_LIVE_E2E claude node perl git jq

CLAUDE_VERSION=$(claude --version 2>/dev/null | head -n 1)
REF=${FM_SUPERVISION_HOST_AWAY_LIVE_REF:-}
LAB=$(fm_test_tmproot fm-supervision-host-away-live)
LAB=$(cd -P "$LAB" && pwd -P)
FM="$LAB/fm"
PR_URL="https://github.com/example/demo/pull/7"
WORDS='continue the queue, max 5 workers, stop at 95% and wait for the reset, do not merge, write me a short "fyi" message with the pr link when a pr is ready for my review'
# The session-lock holder must look like a Claude harness to the ancestry walk
# without shadowing the real claude the engine resolves from PATH.
mkdir -p "$LAB/harness"
ln -s /bin/bash "$LAB/harness/claude"
FAKE_CLAUDE="$LAB/harness/claude"
unset FM_SUPERVISION_ENGINE_CLAUDE_BIN FM_SUPERVISION_ACTOR FM_BRANCH_REPORT_TURN FM_LEASE_HOLDER_PID
unset FM_HOME FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_CONFIG_OVERRIDE FM_DATA_OVERRIDE PI_CODING_AGENT NO_MISTAKES_GATE TYPESAFE_API_KEY

evidence() { printf '# %s %s\n' "$(date '+%H:%M:%S')" "$*"; }

stop_lab() {
  local pid
  if [ -f "$FM/state/.supervision-host" ]; then
    pid=$(awk -F '\t' '$1 == "host" { print $2; exit }' "$FM/state/.supervision-host")
    [ -z "$pid" ] || kill -TERM "$pid" 2>/dev/null || true
    sleep 2
  fi
  pid=$(cat "$FM/state/.watch.lock/pid" 2>/dev/null || true)
  [ -z "$pid" ] || kill -TERM "$pid" 2>/dev/null || true
  while IFS= read -r pid; do
    [ -z "$pid" ] || kill -TERM "$pid" 2>/dev/null || true
  done < "$LAB/claude-pids" 2>/dev/null || true
}
trap 'stop_lab; fm_test_cleanup' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# A lab copy of this checkout's current tree, committed on main, so the lab is
# a genuine primary checkout whose code root is its home.
mkdir -p "$FM"
git -C "$ROOT" ls-files -z -co --exclude-standard \
  | (cd "$ROOT" && tar --null -T - -cf -) | (cd "$FM" && tar -xf -)
if [ -n "$REF" ]; then
  for f in bin/fm-branch-prompt.sh bin/fm-branch-report.sh bin/fm-supervision-host.sh bin/fm-watch.sh; do
    git -C "$ROOT" show "$REF:$f" > "$FM/$f" || fail "control: could not read $f at $REF"
  done
fi

# Recording stand-ins: each appends its arguments to a lab log and answers the
# way the real script answers on success.
stand_in() {  # <script> <log> <reply>
  cat > "$FM/bin/$1" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$LAB/$2"
printf '%s\n' "$3"
SH
  chmod +x "$FM/bin/$1"
}
stand_in fm-send.sh sends.log 'sent'
stand_in fm-spawn.sh spawns.log 'spawned; the worker is processing its brief'
# A spawned task gets the record a real spawn leaves, so later turns see it.
cat >> "$FM/bin/fm-spawn.sh" <<SH
printf 'kind=ship\nproject=demo\nmode=no-mistakes\nyolo=off\nharness=claude\nbackend=tmux\nwindow=fm-%s\n' "\$1" > "$FM/state/\$1.meta"
printf 'state: working · source: pane · the worker is reading its brief\n' > "$FM/lab-crew-state/\$1"
SH
stand_in fm-pr-check.sh pr-checks.log 'PR check armed'
cat > "$FM/bin/fm-crew-state.sh" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$LAB/crew-states.log"
cat "$FM/lab-crew-state/\$1" 2>/dev/null \
  || printf 'state: unknown · source: none · no current-state source available\n'
SH
chmod +x "$FM/bin/fm-crew-state.sh"

git -C "$FM" init -q -b main
git -C "$FM" add -A >/dev/null
git -C "$FM" -c user.name=fmtest -c user.email=fmtest@example.invalid commit -q -m lab
mkdir -p "$FM/state" "$FM/config" "$FM/data/fix-c" "$FM/projects/demo" "$FM/lab-crew-state" "$LAB/tmuxbin"
git -C "$FM/projects/demo" init -q -b main
: > "$FM/config/supervision-host"
printf '#!/usr/bin/env bash\nexit 1\n' > "$LAB/tmuxbin/tmux"
chmod +x "$LAB/tmuxbin/tmux"
printf -- '- demo [no-mistakes] - lab project (added 2026-10-29)\n' > "$FM/data/projects.md"
for task in fix-a fix-b; do
  printf 'kind=ship\nproject=demo\nmode=no-mistakes\nyolo=off\nharness=claude\nbackend=tmux\nwindow=fm-%s\n' "$task" > "$FM/state/$task.meta"
  printf 'working [at=%s]: setup done\n' "$(date +%s)" > "$FM/state/$task.status"
done
cat > "$FM/data/backlog.md" <<'MD'
# Backlog

## In flight
- [ ] fix-a - demo: the export button ignores the filter (repo: demo) (kind: ship) (since 2026-10-29)
  no-mistakes, yolo off.
- [ ] fix-b - demo: the settings page loses unsaved edits (repo: demo) (kind: ship) (since 2026-10-29)
  no-mistakes, yolo off.

## Queued

## Done
MD
FIX_C_BRIEF=$(cat <<'MD'
# Task
## Captain's intent
The search box drops the last typed character; fix it.

## Firstmate spec
- Reproduce the dropped character in the browser, then fix it at the cause.

# Definition of done
Delivery contract: mode=no-mistakes
Ship branch: feature/fix-c
The task is complete only when committed on your branch.
MD
)
FM_HOME="$FM" "$FM/bin/fm-afk-contract.sh" enter --words "$WORDS" --spend 5 >/dev/null \
  || fail "could not record the lab's away posture"

export FM_POLL=1 FM_SIGNAL_GRACE=0 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=${FM_SUPERVISION_HOST_AWAY_LIVE_HEARTBEAT:-60}
FM_HOME="$FM" PATH="$LAB/tmuxbin:$PATH" "$FAKE_CLAUDE" -c '
  printf "%s\n" "$$" > "$FM_HOME/state/.lock"
  printf "%s\n" "$$" >> "$1/claude-pids"
  "$FM_HOME/bin/fm-supervision-host.sh" park > "$1/host.out" 2>&1
  printf "%s\n" "$?" > "$1/host.rc"
' _ "$LAB" 2>> "$LAB/harness.err" &

wait_until() {  # <seconds> <command...>
  local limit=$(( $1 * 10 )) i=0
  shift
  while [ "$i" -lt "$limit" ]; do
    "$@" && return 0
    sleep 0.1
    i=$((i + 1))
  done
  return 1
}
watcher_live() {
  local pid
  pid=$(cat "$FM/state/.watch.lock/pid" 2>/dev/null) || return 1
  [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null
}
host_exited() { [ -s "$LAB/host.rc" ]; }
validation_sent() { grep -E '(^| )fix-a .*no-mistakes' "$LAB/sends.log" >/dev/null 2>&1; }
queued_dispatched() { grep -E '^fix-c ' "$LAB/spawns.log" >/dev/null 2>&1; }
handled_turns() {  # [<since epoch>] [<first reason line>]
  awk -F '\t' -v since="${1:-0}" -v reason="${2:-}" \
    '$1 >= since && $2 == "handled" && (reason == "" || $NF == reason)' \
    "$FM/state/.supervision-host.log" 2>/dev/null | wc -l | tr -d ' '
}
turns_after() { [ "$(handled_turns)" -gt "$1" ]; }
outcomes_for() {  # <task>
  jq -rc --arg t "$1" 'select(.task == $t) | "\(.seq) [\(.verdict)] \(.summary)"' "$FM/state/branch-outcomes.jsonl" 2>/dev/null
}
diagnose() {
  printf -- '--- host.out\n%s\n--- host log\n%s\n--- outcomes\n%s\n--- sends\n%s\n--- spawns\n%s\n' \
    "$(cat "$LAB/host.out" 2>/dev/null)" "$(cut -f1-6 "$FM/state/.supervision-host.log" 2>/dev/null)" \
    "$(cat "$FM/state/branch-outcomes.jsonl" 2>/dev/null)" "$(cat "$LAB/sends.log" 2>/dev/null)" \
    "$(cat "$LAB/spawns.log" 2>/dev/null)"
}

wait_until 30 watcher_live || fail "the host never started a watcher cycle ($CLAUDE_VERSION)"$'\n'"$(diagnose)"
evidence "lab ${REF:-working tree}, $CLAUDE_VERSION, heartbeat every ${FM_HEARTBEAT}s"
FAILED=

# 1. A no-mistakes fix reports its pre-validation done.
TURNS_BEFORE=$(handled_turns)
printf 'state: done · source: status-log · fix committed on feature/fix-a (3f2c1aa); local lint, unit, and e2e green\n' \
  > "$FM/lab-crew-state/fix-a"
printf 'done [at=%s]: fix committed on feature/fix-a (3f2c1aa): the export now applies the filter; local lint, unit, and e2e green\n' \
  "$(date +%s)" >> "$FM/state/fix-a.status"
if wait_until 300 validation_sent; then
  evidence "1 held: validation started: $(grep -E 'fix-a' "$LAB/sends.log" | head -n 1)"
else
  FAILED="$FAILED 1:validation-not-started"
  evidence "1 FAILED: no validation was started for the finished fix within 300s"
fi
evidence "1 outcomes: $(outcomes_for fix-a | tr '\n' '|')"
wait_until 300 turns_after "$TURNS_BEFORE" || evidence "1 note: the finished fix's turn had not ended after 300s"

# 2. A queued item with a written brief and a free slot appears while the fleet
# is quiet, so only a heartbeat can bring it to the away session.
QUEUED_AT=$(date +%s)
printf '%s\n' "$FIX_C_BRIEF" > "$FM/data/fix-c/brief.md"
perl -0pi -e 's/## Queued\n/## Queued\n- [ ] fix-c - demo: the search box drops the last typed character (repo: demo) (kind: ship) (since 2026-10-29)\n  no-mistakes, yolo off.\n/' \
  "$FM/data/backlog.md"
if wait_until 300 queued_dispatched; then
  evidence "2 held: queued work dispatched: $(grep -E '^fix-c ' "$LAB/spawns.log" | head -n 1)"
  grep -E '^fix-c .*--mode no-mistakes' "$LAB/spawns.log" | grep -E -- '--yolo off' >/dev/null \
    || { FAILED="$FAILED 2:wrong-delivery-contract"; evidence "2 FAILED: the spawn did not carry mode no-mistakes and yolo off"; }
else
  FAILED="$FAILED 2:queue-not-dispatched"
  evidence "2 FAILED: the queued item was not dispatched within 300s"
fi
heartbeat_turn_since_queued() { [ "$(handled_turns "$QUEUED_AT" heartbeat)" -gt 0 ]; }
if queued_dispatched && ! wait_until 300 heartbeat_turn_since_queued; then
  FAILED="$FAILED 2:not-on-a-heartbeat"
  evidence "2 FAILED: the queued item was dispatched, but not by a heartbeat turn"
fi
evidence "2 heartbeat turns since queued: $(handled_turns "$QUEUED_AT" heartbeat)"

# 3. A pull request becomes ready for review.
printf 'state: done · source: run-step · PR %s checks green\n' "$PR_URL" > "$FM/lab-crew-state/fix-b"
printf 'pr=%s\n' "$PR_URL" >> "$FM/state/fix-b.meta"
printf 'done [at=%s]: PR %s checks green\n' "$(date +%s)" "$PR_URL" >> "$FM/state/fix-b.status"
if wait_until 300 host_exited && grep -E '^supervision-host: tell: ' "$LAB/host.out" >/dev/null \
  && grep -F "$PR_URL" "$LAB/host.out" | grep -E '^supervision-host: outcome [0-9]+ for [^ ]+ \[captain\]: ' >/dev/null; then
  evidence "3 held: main woken to post: $(grep -E '^supervision-host: outcome' "$LAB/host.out" | head -n 1)"
else
  FAILED="$FAILED 3:fyi-held-for-return"
  evidence "3 FAILED: the ready pull request did not reach main within 300s"
fi
evidence "3 outcomes: $(outcomes_for fix-b | tr '\n' '|')"
[ "$(FM_HOME="$FM" "$FM/bin/fm-afk-contract.sh" mode 2>/dev/null)" = away ] \
  || { FAILED="$FAILED posture-lost"; evidence "FAILED: the captain is no longer recorded away"; }
! grep -q 'fm-pr-merge' "$FM/state/.supervision-host.log" 2>/dev/null || evidence "note: the host log mentions a merge"

[ -z "$FAILED" ] || fail "away live guard on ${REF:-the working tree} ($CLAUDE_VERSION): scenarios that did not hold:$FAILED"$'\n'"$(diagnose)"
pass "away live guard ($CLAUDE_VERSION): a real engine starts validation, dispatches queued work on a heartbeat, and posts a ready PR at once under the captain's away words"
