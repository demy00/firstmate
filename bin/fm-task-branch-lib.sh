# shellcheck shell=bash
# Single owner of the default ship-branch prefix and of the branch a task
# resolves to when its record names none.
# Usage: . bin/fm-task-branch-lib.sh
#
# A ship's branch is `<prefix><task-id>`, and the spawn records that exact name
# as `branch=` in state/<task-id>.meta; that recorded name is authoritative for
# every later lookup (bin/fm-spawn.sh owns the field). A project may register its
# own prefix (bin/fm-project-mode.sh owns the `branch=<prefix>` annotation);
# otherwise the prefix is FM_TASK_BRANCH_DEFAULT_PREFIX, `feature/`. Several
# project repositories run their automated checks only on branches matching
# main, develop, or feature/**, so a worker branch under this prefix gets those
# checks from its first push instead of only after a pull request opens.
#
# Records created before `branch=` existed name no branch. Their work sits under
# the default prefix or under the earlier `fm/` prefix, and a branch is never
# renamed under a running pipeline, so such a record resolves to whichever of
# those names exists locally, current convention first. Remove `fm/` from
# FM_TASK_BRANCH_LEGACY_PREFIXES once no unrecorded fm/<task-id> branch remains
# in any project this home manages.
#
# Functions:
#   fm_task_branch <task-id>
#     Print the default-prefix branch name for <task-id>.
#   fm_task_branch_candidates <task-id>
#     Print every branch name an unrecorded task may hold its work under, one
#     per line, default prefix first, then each legacy prefix.
#   fm_task_branch_resolve <git-dir> <task-id>
#     Print the first candidate that exists as a local branch in <git-dir>;
#     return 1 without output when none does.
#   fm_task_branch_unrecorded <git-dir> <task-id>
#     Print the branch an unrecorded task resolves to: the first existing
#     candidate, or the default-prefix name when none exists yet.
#   fm_task_branch_prefixes_json
#     Print every candidate prefix as a JSON array, default first, for a jq
#     consumer (`--argjson`) that maps a branch name back to its task id with
#     the same prefix set as the shell.

FM_TASK_BRANCH_DEFAULT_PREFIX=feature/
FM_TASK_BRANCH_LEGACY_PREFIXES="fm/"

fm_task_branch() {
  local id=$1
  printf '%s%s\n' "$FM_TASK_BRANCH_DEFAULT_PREFIX" "$id"
}

fm_task_branch_candidates() {
  local id=$1 prefix
  printf '%s%s\n' "$FM_TASK_BRANCH_DEFAULT_PREFIX" "$id"
  for prefix in $FM_TASK_BRANCH_LEGACY_PREFIXES; do
    printf '%s%s\n' "$prefix" "$id"
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

fm_task_branch_unrecorded() {
  local dir=$1 id=$2
  fm_task_branch_resolve "$dir" "$id" || fm_task_branch "$id"
}

fm_task_branch_prefixes_json() {
  local prefix out=''
  for prefix in "$FM_TASK_BRANCH_DEFAULT_PREFIX" $FM_TASK_BRANCH_LEGACY_PREFIXES; do
    out="${out:+$out,}\"$prefix\""
  done
  printf '[%s]\n' "$out"
}
