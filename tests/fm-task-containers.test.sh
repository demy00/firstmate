#!/usr/bin/env bash
# Behavior tests for bin/fm-task-containers.sh.
#
# A finished task's Docker containers must stop with it, and only containers
# Docker itself records as started from the task's own paths may be touched.
# Cases drive the script's argv interface against tests/fixtures.sh's fake
# `docker` (named through the FM_TEST_DOCKER seam) whose running containers
# each case writes, and a fake `no-mistakes` that answers
# `axi status --run <id>` from a run-to-branch table, so no case touches a real
# Docker engine or pipeline daemon.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"
fm_git_identity fmtest fmtest@example.invalid

TOOL="$ROOT/bin/fm-task-containers.sh"
TMP_ROOT=$(fm_test_tmproot fm-task-containers)
FAKEBIN=$(fm_fakebin "$TMP_ROOT")
DOCKER_DIR="$TMP_ROOT/docker"
NM_HOME="$TMP_ROOT/nm"
NM_RUNS="$TMP_ROOT/nm-runs"
NM_CALLS="$TMP_ROOT/nm-calls"
WT="$TMP_ROOT/pool/1/repo"
TASKTMP="$TMP_ROOT/tasktmp"
BRANCH=feature/task-c1
mkdir -p "$DOCKER_DIR" "$NM_HOME/repos/abc123.git" "$NM_HOME/worktrees/abc123" "$TASKTMP"
fm_git_init_commit "$WT"
git -C "$WT" checkout -q -b "$BRANCH"
git -C "$WT" remote add no-mistakes "$NM_HOME/repos/abc123.git"

fm_test_fake_docker "$FAKEBIN"
# A fake no-mistakes: `axi status --run <id>` answers the run's branch from
# $NM_RUNS (one "<id> <branch>" per line) and refuses an unknown run. Each
# looked-up run id is appended to $FAKE_NM_CALLS.
cat > "$FAKEBIN/no-mistakes" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "${4:-}" >> "$FAKE_NM_CALLS"
[ "$1 $2 $3" = "axi status --run" ] || exit 1
branch=$(awk -v id="$4" '$1 == id { print $2 }' "$FAKE_NM_RUNS")
[ -n "$branch" ] || { printf 'error: "run \\"%s\\" not found"\n' "$4" >&2; exit 1; }
printf 'current_branch: main\nother_branch_run:\n  id: "%s"\n  branch: %s\n  status: completed\n' "$4" "$branch"
SH
chmod +x "$FAKEBIN/no-mistakes"

reset_docker() {
  rm -rf "$DOCKER_DIR"
  mkdir -p "$DOCKER_DIR"
  : > "$DOCKER_DIR/running"
  : > "$NM_RUNS"
  : > "$NM_CALLS"
}

add_container() { fm_test_fake_docker_container "$DOCKER_DIR" "$@"; }

run_tool() {
  FM_TEST_DOCKER="$FAKEBIN/docker" FAKE_DOCKER_DIR="$DOCKER_DIR" FAKE_NM_RUNS="$NM_RUNS" FAKE_NM_CALLS="$NM_CALLS" \
    PATH="$FAKEBIN:$PATH" "$TOOL" "$@"
}

stopped() { cat "$DOCKER_DIR/stopped" 2>/dev/null; }

test_stops_only_containers_started_from_task_paths() {
  local out rc
  reset_docker
  add_container aaa111 compose_web 2026-10-15T10:00:00.1Z /elsewhere/repo "/elsewhere/repo/docker-compose.yml,$WT/compose/app.yml"
  add_container bbb222 dbs_db 2026-10-15T10:00:00.1Z "$WT" "$WT/docker-compose.yml"
  add_container ccc333 scratch_pg 2026-10-15T10:00:00.1Z '' '' "$TASKTMP/pgdata"
  add_container ddd444 captain_db 2026-10-15T10:00:00.1Z /Users/captain/stack /Users/captain/stack/compose.yml /Users/captain/stack/data
  add_container eee555 sibling_db 2026-10-15T10:00:00.1Z '' '' "${WT}-other/data" "${TASKTMP}2"
  add_container fff666 plain_pg 2026-10-15T10:00:00.1Z '' ''
  set +e
  out=$(run_tool stop --task task-c1 --worktree "$WT" --tasktmp "$TASKTMP" 2>&1)
  rc=$?
  set -e
  expect_code 0 "$rc" "stopping proven task containers succeeds"
  [ "$(stopped | sort | tr '\n' ' ')" = "aaa111 bbb222 ccc333 " ] \
    || fail "expected exactly the task's three containers stopped, got: $(stopped | tr '\n' ' ')"
  assert_contains "$out" "stopped Docker container compose_web (aaa111) for task-c1: compose config file $WT/compose/app.yml is in the task worktree" "output check"
  assert_contains "$out" "stopped Docker container dbs_db (bbb222) for task-c1: compose working dir $WT is in the task worktree" "output check"
  assert_contains "$out" "stopped Docker container scratch_pg (ccc333) for task-c1: bind mount $TASKTMP/pgdata is in the task temp dir" "output check"
  assert_not_contains "$out" captain_db "output check"
  assert_not_contains "$out" sibling_db "output check"
  assert_not_contains "$out" plain_pg "output check"
  pass "stop touches only containers whose compose files, working dir, or bind mounts are in the task's own paths"
}

test_list_reports_without_stopping() {
  local out
  reset_docker
  add_container bbb222 dbs_db 2026-10-15T10:00:00.1Z "$WT" "$WT/docker-compose.yml"
  out=$(run_tool list --task task-c1 --worktree "$WT" 2>&1) || fail "list failed: $out"
  assert_contains "$out" "would stop Docker container dbs_db (bbb222) for task-c1: compose working dir $WT is in the task worktree" "output check"
  [ -z "$(stopped)" ] || fail "list stopped a container"
  pass "list names the task's containers and stops nothing"
}

test_no_mistakes_run_worktree_belongs_only_on_the_task_branch() {
  local out
  reset_docker
  printf '%s %s\n' 01RUNMINE "$BRANCH" 01RUNOTHER feature/someone-else > "$NM_RUNS"
  add_container kc1 odkc-nm-mine 2026-10-15T10:00:00.1Z '' '' "$NM_HOME/worktrees/abc123/01RUNMINE/keycloak"
  add_container kc2 odkc-nm-other 2026-10-15T10:00:00.1Z '' '' "$NM_HOME/worktrees/abc123/01RUNOTHER/keycloak"
  add_container kc3 odkc-nm-unknown 2026-10-15T10:00:00.1Z '' '' "$NM_HOME/worktrees/abc123/01RUNGONE/keycloak"
  add_container kc4 odkc-nm-otherrepo 2026-10-15T10:00:00.1Z '' '' "$NM_HOME/worktrees/zzz999/01RUNMINE/keycloak"
  out=$(run_tool stop --task task-c1 --worktree "$WT" 2>&1) || fail "stop failed: $out"
  [ "$(stopped)" = kc1 ] || fail "expected only the task-branch run's container stopped, got: $(stopped | tr '\n' ' ')"
  assert_contains "$out" "bind mount $NM_HOME/worktrees/abc123/01RUNMINE/keycloak is in no-mistakes run 01RUNMINE's worktree for $BRANCH" "output check"
  pass "a no-mistakes run worktree counts only for this repo's runs on the task's own branch"
}

test_each_no_mistakes_run_is_looked_up_once() {
  local out
  reset_docker
  printf '%s %s\n' 01RUNOTHER feature/someone-else > "$NM_RUNS"
  add_container kc1 odkc-a 2026-10-15T10:00:00.1Z "$NM_HOME/worktrees/abc123/01RUNOTHER/kc" \
    "$NM_HOME/worktrees/abc123/01RUNOTHER/kc/compose.yml" "$NM_HOME/worktrees/abc123/01RUNOTHER/kc/data"
  add_container kc2 odkc-b 2026-10-15T10:00:00.1Z '' '' \
    "$NM_HOME/worktrees/abc123/01RUNOTHER/a" "$NM_HOME/worktrees/abc123/01RUNOTHER/b"
  out=$(run_tool stop --task task-c1 --worktree "$WT" 2>&1) || fail "stop failed: $out"
  [ -z "$(stopped)" ] || fail "stopped another branch's run container"
  [ "$(cat "$NM_CALLS")" = 01RUNOTHER ] \
    || fail "expected one no-mistakes lookup for the run, got: $(tr '\n' ' ' < "$NM_CALLS")"
  pass "a no-mistakes run is looked up once however many paths point into its worktree"
}

test_container_vanishing_before_inspect_still_stops_the_rest() {
  local out rc
  reset_docker
  printf '%s\n' gone000 >> "$DOCKER_DIR/running"
  add_container bbb222 dbs_db 2026-10-15T10:00:00.1Z "$WT" "$WT/docker-compose.yml"
  set +e
  out=$(run_tool stop --task task-c1 --worktree "$WT" 2>&1)
  rc=$?
  set -e
  expect_code 0 "$rc" "a vanished container is not a failure"
  [ "$(stopped)" = bbb222 ] || fail "expected the task's container stopped, got: $(stopped | tr '\n' ' ')"
  assert_not_contains "$out" "not reachable" "output check"
  pass "a container that exits between ps and inspect does not skip the task's other containers"
}

test_reused_slot_ignores_containers_started_before_the_task() {
  local out
  reset_docker
  add_container old1 earlier_stack 2026-10-15T09:59:59.9Z "$WT" "$WT/docker-compose.yml"
  add_container new1 own_stack 2026-10-15T10:00:00.0Z "$WT" "$WT/docker-compose.yml"
  out=$(run_tool stop --task task-c1 --worktree "$WT" --worktree-since 2026-10-15T10:00:00Z 2>&1) \
    || fail "stop failed: $out"
  [ "$(stopped)" = new1 ] || fail "expected only the container started after the claim stopped, got: $(stopped | tr '\n' ' ')"
  assert_not_contains "$out" earlier_stack "output check"
  pass "a container started in a reused slot before the task took it is left running"
}

test_symlinked_task_path_matches_its_physical_form() {
  local out
  reset_docker
  mkdir -p "$TMP_ROOT/real-tmp/fm-task-c1"
  ln -s "$TMP_ROOT/real-tmp" "$TMP_ROOT/tmp-link"
  add_container ln1 linked_pg 2026-10-15T10:00:00.1Z '' '' "$TMP_ROOT/real-tmp/fm-task-c1/data"
  out=$(run_tool stop --task task-c1 --tasktmp "$TMP_ROOT/tmp-link/fm-task-c1" 2>&1) || fail "stop failed: $out"
  [ "$(stopped)" = ln1 ] || fail "expected the container recorded under the physical path stopped, got: $(stopped | tr '\n' ' ')"
  pass "a task path given through a symlink (macOS /tmp) also matches the physical path Docker recorded"
}

test_docker_not_installed_is_reported_and_succeeds() {
  local out rc
  reset_docker
  set +e
  out=$(FM_TEST_DOCKER=fm-test-docker-absent-zz "$TOOL" stop --task task-c1 --worktree "$WT" 2>&1)
  rc=$?
  set -e
  expect_code 0 "$rc" "missing docker is not a failure"
  assert_contains "$out" "Docker is not installed; no containers to stop for task-c1" "output check"
  pass "missing Docker is reported and does not fail"
}

test_docker_daemon_down_is_reported_and_succeeds() {
  local out rc
  reset_docker
  add_container bbb222 dbs_db 2026-10-15T10:00:00.1Z "$WT" "$WT/docker-compose.yml"
  set +e
  out=$(FAKE_DOCKER_UP=0 run_tool stop --task task-c1 --worktree "$WT" 2>&1)
  rc=$?
  set -e
  expect_code 0 "$rc" "an unreachable daemon is not a failure"
  assert_contains "$out" "Docker is not reachable" "output check"
  assert_contains "$out" "task-c1's containers were not checked" "output check"
  [ -z "$(stopped)" ] || fail "stopped a container with the daemon down"
  pass "an unreachable Docker daemon is reported and does not fail"
}

test_stop_failure_is_reported_and_fails() {
  local out rc
  reset_docker
  add_container bbb222 dbs_db 2026-10-15T10:00:00.1Z "$WT" "$WT/docker-compose.yml"
  add_container ccc333 scratch_pg 2026-10-15T10:00:00.1Z '' '' "$TASKTMP/pgdata"
  set +e
  out=$(FAKE_DOCKER_STOP_FAIL=bbb222 run_tool stop --task task-c1 --worktree "$WT" --tasktmp "$TASKTMP" 2>&1)
  rc=$?
  set -e
  expect_code 1 "$rc" "a container that would not stop fails the run"
  assert_contains "$out" "could not stop Docker container dbs_db (bbb222) for task-c1" "output check"
  assert_contains "$out" "stopped Docker container scratch_pg (ccc333) for task-c1" "output check"
  pass "a container that will not stop is named and fails the run while the rest still stop"
}

test_no_task_paths_touch_nothing() {
  local out
  reset_docker
  add_container bbb222 dbs_db 2026-10-15T10:00:00.1Z "$WT" "$WT/docker-compose.yml"
  out=$(run_tool stop --task task-c1 2>&1) || fail "stop failed: $out"
  [ -z "$out" ] || fail "expected no output without task paths, got: $out"
  [ -z "$(stopped)" ] || fail "stopped a container with no task paths"
  pass "with no task paths nothing is matched or stopped"
}

test_usage_errors() {
  local rc
  set +e
  "$TOOL" stop >/dev/null 2>&1; rc=$?
  set -e
  expect_code 2 "$rc" "missing --task is a usage error"
  set +e
  "$TOOL" stop --task t --worktree-since yesterday >/dev/null 2>&1; rc=$?
  set -e
  expect_code 2 "$rc" "a malformed --worktree-since is a usage error"
  pass "usage errors exit 2"
}

test_stops_only_containers_started_from_task_paths
test_list_reports_without_stopping
test_no_mistakes_run_worktree_belongs_only_on_the_task_branch
test_each_no_mistakes_run_is_looked_up_once
test_container_vanishing_before_inspect_still_stops_the_rest
test_reused_slot_ignores_containers_started_before_the_task
test_symlinked_task_path_matches_its_physical_form
test_docker_not_installed_is_reported_and_succeeds
test_docker_daemon_down_is_reported_and_succeeds
test_stop_failure_is_reported_and_fails
test_no_task_paths_touch_nothing
test_usage_errors
echo "# all fm-task-containers tests passed"
