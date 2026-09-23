#!/usr/bin/env bash
# Behavior tests for bin/fm-task-branch-lib.sh, the one owner of the worker
# branch naming convention.
#
# A new worker branch is named feature/<task-id>, so project repositories whose
# automated checks run only on main, develop, or feature/** branches check a
# worker branch from its first push. Branches created under the earlier
# fm/<task-id> name are never renamed, because a running pipeline owns them, so
# every lookup must keep resolving them while the current name wins whenever
# both exist. A rename that creates under one name and looks up under another
# silently loses the task; these tests pin both halves together.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_git_identity fmtest fmtest@example.invalid

TMP_ROOT=$(fm_test_tmproot fm-task-branch-lib)

# shellcheck source=bin/fm-task-branch-lib.sh
. "$ROOT/bin/fm-task-branch-lib.sh"

test_new_branch_is_named_feature() {
  local out
  out=$(fm_task_branch build-widget-a1)
  [ "$out" = "feature/build-widget-a1" ] \
    || fail "a new worker branch must be feature/<task-id>, got '$out'"
  pass "fm_task_branch names a new worker branch feature/<task-id>"
}

test_candidates_list_current_name_first_then_legacy() {
  local out
  out=$(fm_task_branch_candidates build-widget-a1 | tr '\n' ' ')
  [ "$out" = "feature/build-widget-a1 fm/build-widget-a1 " ] \
    || fail "candidates must be the current name then the legacy name, got '$out'"
  pass "fm_task_branch_candidates lists feature/<id> before fm/<id>"
}

test_prefixes_json_matches_shell_order() {
  local out
  out=$(fm_task_branch_prefixes_json)
  [ "$out" = '["feature","fm"]' ] || fail "prefixes JSON must list feature then fm, got '$out'"
  printf '%s' "$out" | jq -e 'type == "array"' >/dev/null \
    || fail "prefixes JSON must be valid JSON: $out"
  pass "fm_task_branch_prefixes_json mirrors the shell prefix order for jq consumers"
}

# Resolution against a real repository: the current name when it exists, the
# legacy name when only it exists, the current name when both exist, and no
# guess when neither does.
test_resolve_prefers_feature_then_falls_back_to_fm() {
  local repo out
  repo="$TMP_ROOT/resolve"
  fm_git_init_commit "$repo"

  if out=$(fm_task_branch_resolve "$repo" task-r1); then
    fail "a task with no branch must not resolve, got '$out'"
  fi
  [ -z "$out" ] || fail "an unresolved task must print nothing, got '$out'"

  git -C "$repo" branch -q fm/task-r1
  out=$(fm_task_branch_resolve "$repo" task-r1) \
    || fail "a task whose only branch is fm/<id> must resolve"
  [ "$out" = fm/task-r1 ] || fail "legacy-only task resolved to '$out'"

  git -C "$repo" branch -q feature/task-r1
  out=$(fm_task_branch_resolve "$repo" task-r1) \
    || fail "a task with both branches must resolve"
  [ "$out" = feature/task-r1 ] || fail "with both branches present the current name must win, got '$out'"

  git -C "$repo" branch -q -D fm/task-r1
  out=$(fm_task_branch_resolve "$repo" task-r1) \
    || fail "a task whose only branch is feature/<id> must resolve"
  [ "$out" = feature/task-r1 ] || fail "current-only task resolved to '$out'"
  pass "fm_task_branch_resolve prefers feature/<id> and still finds fm/<id>"
}

# The guarded local-only landing looks the worker branch up by task id, so a
# lane that started under fm/<id> before the rename must still land, and a new
# lane lands from feature/<id>.
test_merge_local_lands_both_branch_names() {
  local branch id home proj wt before after
  for branch in feature fm; do
    id="land-$branch-1"
    home="$TMP_ROOT/merge-$branch"
    mkdir -p "$home/state" "$home/data" "$home/config" "$home/projects"
    proj="$home/projects/sample"
    wt="$home/projects/$id"
    fm_git_worktree "$proj" "$wt" "$branch/$id"
    printf 'landed from %s\n' "$branch" > "$wt/delivery.txt"
    git -C "$wt" add delivery.txt
    git -C "$wt" commit -qm "delivery on $branch/$id"
    fm_write_meta "$home/state/$id.meta" \
      "window=firstmate:fm-$id" "endpoint_task_id=$id" "worktree=$wt" \
      "project=$proj" "harness=codex" "kind=ship" "mode=local-only" \
      "spawn_gen=fixture-$id"
    before=$(git -C "$proj" rev-parse main)
    FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
      FM_DATA_OVERRIDE="$home/data" FM_CONFIG_OVERRIDE="$home/config" \
      "$ROOT/bin/fm-merge-local.sh" "$id" > "$home/merge.out" 2> "$home/merge.err" \
      || fail "$branch/$id: the local landing refused a ready branch: $(cat "$home/merge.err")"
    after=$(git -C "$proj" rev-parse main)
    [ "$after" != "$before" ] || fail "$branch/$id: the local landing did not advance main"
    [ "$after" = "$(git -C "$proj" rev-parse "$branch/$id")" ] \
      || fail "$branch/$id: main did not land on the worker branch tip"
  done
  pass "fm-merge-local lands a feature/<id> branch and a pre-rename fm/<id> branch"
}

test_new_branch_is_named_feature
test_candidates_list_current_name_first_then_legacy
test_prefixes_json_matches_shell_order
test_resolve_prefers_feature_then_falls_back_to_fm
test_merge_local_lands_both_branch_names
