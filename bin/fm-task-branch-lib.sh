# shellcheck shell=bash
# Single owner of the worker branch naming convention.
# Usage: . bin/fm-task-branch-lib.sh
#
# Every branch firstmate asks a worker to create is named
# `feature/<task-id>`. The `feature/` prefix is deliberate: several project
# repositories run their automated checks only on branches matching main,
# develop, or feature/**, so a worker branch under this prefix gets those
# checks from its first push instead of only after a pull request opens.
#
# Branches created before this convention are named `fm/<task-id>`. They are
# never renamed: renaming a branch under a running pipeline would strand it.
# Every lookup, match, and parse therefore recognises both prefixes, in
# preference order, while only the creation path uses the current one.
# Remove the legacy prefix from FM_TASK_BRANCH_LEGACY_PREFIXES once no
# fm/<task-id> branch remains in any project this home manages.
#
# Functions:
#   fm_task_branch <task-id>
#     Print the branch name a NEW worker for <task-id> must create.
#   fm_task_branch_candidates <task-id>
#     Print every branch name that may hold <task-id>'s work, one per line,
#     current convention first, then each legacy prefix.
#   fm_task_branch_resolve <git-dir> <task-id>
#     Print the first candidate that exists as a local branch in <git-dir>;
#     return 1 without output when none does.
#   fm_task_branch_prefixes_json
#     Print every recognised prefix as a JSON array, current convention first,
#     for a jq consumer (`--argjson`) that maps branch names back to task ids
#     with the same prefix set as the shell.

FM_TASK_BRANCH_PREFIX=feature
FM_TASK_BRANCH_LEGACY_PREFIXES="fm"

fm_task_branch() {
  local id=$1
  printf '%s/%s\n' "$FM_TASK_BRANCH_PREFIX" "$id"
}

fm_task_branch_candidates() {
  local id=$1 prefix
  printf '%s/%s\n' "$FM_TASK_BRANCH_PREFIX" "$id"
  for prefix in $FM_TASK_BRANCH_LEGACY_PREFIXES; do
    printf '%s/%s\n' "$prefix" "$id"
  done
}

fm_task_branch_resolve() {
  local dir=$1 id=$2 candidate
  while IFS= read -r candidate; do
    if git -C "$dir" rev-parse --verify --quiet "refs/heads/$candidate" >/dev/null 2>&1; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done < <(fm_task_branch_candidates "$id")
  return 1
}

fm_task_branch_prefixes_json() {
  local prefix out=''
  for prefix in "$FM_TASK_BRANCH_PREFIX" $FM_TASK_BRANCH_LEGACY_PREFIXES; do
    out="${out:+$out,}\"$prefix\""
  done
  printf '[%s]\n' "$out"
}
