#!/usr/bin/env bash
# Behavior tests for bin/fm-project-yolo-apply.sh: after the captain changes a
# project's registered +yolo posture in data/projects.md, one command makes
# that project's live ship tasks in this home carry the new merge authority.
#
# The 2026-10-19 overnight stall motivates it: a project switched to +yolo in
# the evening still had three running tasks recorded yolo=off at spawn, so
# their green PRs waited all night for the captain.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

APPLY="$ROOT/bin/fm-project-yolo-apply.sh"
TMP_ROOT=$(fm_test_tmproot fm-project-yolo-apply)

new_home() {  # <name> <ada-registry-annotation> -> echoes home
  local home="$TMP_ROOT/$1"
  mkdir -p "$home/state" "$home/data" "$home/projects/ada" "$home/projects/other"
  {
    printf '# Projects\n\n'
    printf -- '- ada %s - Ada library (added 2026-10-01)\n' "$2"
    printf -- '- other [no-mistakes] - another library (added 2026-10-01)\n'
  } > "$home/data/projects.md"
  fm_write_meta "$home/state/ada-1.meta" "window=fm-ada-1" "worktree=$home/wt/ada-1" \
    "project=$home/projects/ada" "harness=claude" "kind=ship" "mode=no-mistakes" "yolo=off" \
    "branch=feature/ada-1" "pr=https://github.com/o/ada/pull/7"
  fm_write_meta "$home/state/ada-2.meta" "window=fm-ada-2" "project=$home/projects/ada" \
    "kind=ship" "mode=no-mistakes" "yolo=off"
  fm_write_meta "$home/state/ada-scout.meta" "window=fm-ada-scout" "project=$home/projects/ada" "kind=scout"
  fm_write_meta "$home/state/other-1.meta" "window=fm-other-1" "project=$home/projects/other" \
    "kind=ship" "mode=no-mistakes" "yolo=off"
  printf '%s\n' "$home"
}

apply() {  # <home> <args...>
  local home=$1
  shift
  FM_HOME="$home" "$APPLY" "$@" 2>&1
}

meta_yolo() {  # <home> <id>
  grep '^yolo=' "$1/state/$2.meta" | tail -1 | cut -d= -f2-
}

test_live_tasks_follow_a_project_switched_to_yolo() {
  local home out rc
  home=$(new_home switch-on '[no-mistakes +yolo]')
  out=$(apply "$home" ada)
  rc=$?
  expect_code 0 "$rc" "applying the registered posture"
  assert_equals on "$(meta_yolo "$home" ada-1)" "a running ada ship did not follow the project's +yolo"
  assert_equals on "$(meta_yolo "$home" ada-2)" "every running ada ship must follow the project's +yolo"
  assert_equals off "$(meta_yolo "$home" other-1)" "another project's task changed posture"
  assert_no_grep 'yolo=' "$home/state/ada-scout.meta" "a scout gained a merge posture it never carries"
  assert_grep 'pr=https://github.com/o/ada/pull/7' "$home/state/ada-1.meta" "the rewrite lost the task's other fields"
  assert_grep 'branch=feature/ada-1' "$home/state/ada-1.meta" "the rewrite lost the task's other fields"
  [ "$(grep -c '^yolo=' "$home/state/ada-1.meta")" -eq 1 ] || fail "the rewrite left two yolo lines"
  assert_contains "$out" "ada-1: yolo off -> on" "the change for ada-1 was not reported"
  assert_contains "$out" "ada-2: yolo off -> on" "the change for ada-2 was not reported"
  assert_not_contains "$out" "other-1" "another project's task was reported"

  # Running it again changes nothing and says so.
  out=$(apply "$home" ada)
  rc=$?
  expect_code 0 "$rc" "a repeat apply"
  assert_contains "$out" "ada-1: yolo on (unchanged)" "a repeat apply did not report the unchanged task"
  pass "a project switched to +yolo hands its live ship tasks the new merge authority, and nothing else"
}

test_live_tasks_follow_a_project_switched_off_yolo() {
  local home out rc
  home=$(new_home switch-off '[no-mistakes]')
  printf 'yolo=on\n' >> "$home/state/ada-1.meta"
  out=$(apply "$home" ada)
  rc=$?
  expect_code 0 "$rc" "applying the registered posture"
  assert_equals off "$(meta_yolo "$home" ada-1)" "a running ada ship kept merge authority the captain withdrew"
  assert_contains "$out" "ada-1: yolo on -> off" "the withdrawal was not reported"
  pass "a project switched off +yolo takes merge authority back from its live ship tasks"
}

test_gerrit_project_never_gains_yolo() {
  local home out
  home=$(new_home gerrit '[no-mistakes forge=gerrit +yolo]')
  out=$(apply "$home" ada)
  assert_equals off "$(meta_yolo "$home" ada-1)" "a Gerrit project's task gained yolo"
  assert_contains "$out" "yolo is inactive for forge=gerrit" "the Gerrit refusal was not passed through"
  pass "a Gerrit project's live tasks never gain merge authority"
}

test_unreadable_posture_changes_nothing() {
  local home out rc before
  home=$(new_home malformed '[no-mistakes forge=bogus +yolo]')
  before=$(cat "$home/state/ada-1.meta")
  out=$(apply "$home" ada)
  rc=$?
  [ "$rc" -ne 0 ] || fail "an unreadable registry posture was applied: $out"
  assert_equals "$before" "$(cat "$home/state/ada-1.meta")" "an unreadable posture rewrote a task"
  assert_contains "$out" "unknown forge" "the registry refusal was not passed through"
  pass "a registry posture that does not resolve changes no task"
}

test_named_tasks_limit_the_apply() {
  local home out rc
  home=$(new_home named '[no-mistakes +yolo]')
  out=$(apply "$home" ada ada-2)
  rc=$?
  expect_code 0 "$rc" "applying to one named task"
  assert_equals on "$(meta_yolo "$home" ada-2)" "the named task did not follow the posture"
  assert_equals off "$(meta_yolo "$home" ada-1)" "a task left out of the list was changed"
  out=$(apply "$home" ada other-1)
  rc=$?
  [ "$rc" -ne 0 ] || fail "a task of another project was accepted: $out"
  assert_equals off "$(meta_yolo "$home" other-1)" "another project's named task was changed"
  assert_contains "$out" "other-1 is not a live ship task of ada" "the refusal did not name the task"
  out=$(apply "$home" ada ada-scout)
  rc=$?
  [ "$rc" -ne 0 ] || fail "a scout was accepted as a ship task: $out"
  pass "named task ids limit the apply to those live ship tasks of the project"
}

test_task_under_a_lifecycle_action_is_left_for_a_rerun() {
  local home out rc holder i
  home=$(new_home locked '[no-mistakes +yolo]')
  # shellcheck disable=SC2016 # Positional parameters expand in the child shell.
  FM_STATE_OVERRIDE="$home/state" bash -c '. "$1"; fm_lock_try_acquire "$2" || exit 1; : > "$3"; sleep 30' \
    _ "$ROOT/bin/fm-wake-lib.sh" "$home/state/.control-ada-2.lock" "$home/held" &
  holder=$!
  i=0
  while [ ! -f "$home/held" ]; do
    i=$((i + 1))
    [ "$i" -lt 100 ] || fail "the lifecycle lock holder never started"
    sleep 0.05
  done
  out=$(apply "$home" ada)
  rc=$?
  kill "$holder" 2>/dev/null || true
  wait "$holder" 2>/dev/null || true
  [ "$rc" -ne 0 ] || fail "a task under a lifecycle action was reported applied: $out"
  assert_equals on "$(meta_yolo "$home" ada-1)" "the free task was not applied"
  assert_equals off "$(meta_yolo "$home" ada-2)" "a task under a lifecycle action was rewritten"
  assert_contains "$out" "ada-2: skipped" "the skipped task was not named"
  out=$(apply "$home" ada)
  rc=$?
  expect_code 0 "$rc" "the rerun after the lifecycle action ended"
  assert_equals on "$(meta_yolo "$home" ada-2)" "the rerun did not apply the skipped task"
  pass "a task under a lifecycle action is left untouched and named for a rerun"
}

test_usage() {
  local out rc
  out=$("$APPLY" 2>&1)
  rc=$?
  expect_code 2 "$rc" "no project"
  assert_contains "$out" "usage:" "no usage line"
  out=$("$APPLY" --help 2>&1)
  rc=$?
  expect_code 0 "$rc" "--help"
  assert_contains "$out" "fm-project-yolo-apply.sh <project>" "help lost the usage"
  pass "usage errors exit 2 and --help prints the usage"
}

test_live_tasks_follow_a_project_switched_to_yolo
test_live_tasks_follow_a_project_switched_off_yolo
test_gerrit_project_never_gains_yolo
test_unreadable_posture_changes_nothing
test_named_tasks_limit_the_apply
test_task_under_a_lifecycle_action_is_left_for_a_rerun
test_usage
