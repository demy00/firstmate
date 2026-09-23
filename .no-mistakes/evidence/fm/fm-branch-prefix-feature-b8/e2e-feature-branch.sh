#!/usr/bin/env bash
# Manual end-to-end evidence for: worker branches are named feature/<task-id>,
# while branches created earlier as fm/<task-id> still resolve everywhere.
set -u
ROOT=/Users/demy00/.no-mistakes/worktrees/f2cfe607828c/01M37N1B146PY49H0CTEEF6YX4
EV=/Users/demy00/.no-mistakes/evidence/01M37N1B146PY49H0CTEEF6YX4
. "$ROOT/tests/lib.sh"
fm_git_identity fmtest fmtest@example.invalid
T=$(fm_test_tmproot e2e-feature-branch)

hr() { printf '\n===== %s =====\n' "$*"; }

exit_after_d=1
[ "${ONLY_D:-0}" = 1 ] && skip_abc=1 || skip_abc=0
if [ "$skip_abc" = 0 ]; then
hr "A. fm-brief.sh: the rendered brief tells a NEW worker to create feature/<task-id>"
home="$T/brief-home"; mkdir -p "$home/data"
for id_mode in "add-login-a1:no-mistakes" "fix-header-b2:direct-PR" "tidy-docs-c3:local-only"; do
  id=${id_mode%%:*}; mode=${id_mode##*:}
  printf '\n$ fm-brief.sh %s some-proj --mode %s\n' "$id" "$mode"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" some-proj --mode "$mode" 2>&1 | sed 's/^/  /'
  printf -- '-- lines of data/%s/brief.md that name the worker branch:\n' "$id"
  grep -n 'feature/\|fm/' "$home/data/$id/brief.md" | sed 's/^/  /'
done
cp "$home/data/tidy-docs-c3/brief.md" "$EV/rendered-brief-local-only.md"

hr "B. fm-merge-local.sh: lands a feature/<id> branch AND a pre-rename fm/<id> branch"
for branch in feature fm; do
  id="land-$branch-1"; h="$T/merge-$branch"
  mkdir -p "$h/state" "$h/data" "$h/config" "$h/projects"
  proj="$h/projects/sample"; wt="$h/projects/$id"
  fm_git_worktree "$proj" "$wt" "$branch/$id"
  printf 'landed from %s\n' "$branch" > "$wt/delivery.txt"
  git -C "$wt" add delivery.txt; git -C "$wt" commit -qm "delivery on $branch/$id"
  fm_write_meta "$h/state/$id.meta" "window=firstmate:fm-$id" "endpoint_task_id=$id" \
    "worktree=$wt" "project=$proj" "harness=codex" "kind=ship" "mode=local-only" "spawn_gen=fixture-$id"
  printf '\n$ git -C sample branch --list        # before\n'; git -C "$proj" branch --list | sed 's/^/  /'
  printf '$ git -C sample log --oneline main    # before\n'; git -C "$proj" log --oneline main | sed 's/^/  /'
  printf '$ fm-merge-local.sh %s\n' "$id"
  FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$h" FM_STATE_OVERRIDE="$h/state" FM_DATA_OVERRIDE="$h/data" \
    FM_CONFIG_OVERRIDE="$h/config" "$ROOT/bin/fm-merge-local.sh" "$id" 2>&1 | sed 's/^/  /'
  printf '  exit=%s\n' "${PIPESTATUS[0]}"
  printf '$ git -C sample log --oneline main    # after\n'; git -C "$proj" log --oneline main | sed 's/^/  /'
done

hr "C. fm-review-diff.sh: reviews the task branch under feature/ and under legacy fm/"
for branch in feature fm; do
  id="task-x1"; c="$T/review-$branch"; mkdir -p "$c/state"
  fm_git_init_commit "$c/seed"; fm_git_add_origin "$c/seed" "$c/origin.git"
  git clone -q "$c/origin.git" "$c/project"; git -C "$c/project" remote set-head origin main 2>/dev/null || true
  git -C "$c/project" worktree add -q -b "$branch/$id" "$c/wt" main
  printf 'change made on %s/%s\n' "$branch" "$id" > "$c/wt/feature.txt"
  git -C "$c/wt" add feature.txt; git -C "$c/wt" commit -qm "work on $branch/$id"
  git -C "$c/wt" checkout -q --detach main   # park the worktree elsewhere: lookup must be by name
  fm_write_meta "$c/state/$id.meta" "window=firstmate:fm-$id" "endpoint_task_id=$id" \
    "worktree=$c/wt" "project=$c/project" "harness=codex" "kind=ship" "mode=direct-PR"
  touch "$c/state/.last-watcher-beat"
  printf '\n$ git -C wt branch --list\n'; git -C "$c/wt" branch --list | sed 's/^/  /'
  printf '$ fm-review-diff.sh %s\n' "$id"
  FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$c" FM_STATE_OVERRIDE="$c/state" "$ROOT/bin/fm-review-diff.sh" "$id" 2>&1 | sed 's/^/  /'
done

fi
hr "D. fm-bearings-snapshot.sh --include-prs: PR head -> task mapping"
# Reuse the bearings suite's own fixture helpers (everything before its first test).
sed -n '1,369p' "$ROOT/tests/fm-bearings-snapshot.test.sh" \
  | sed "s#^\. \"\$(dirname \"\${BASH_SOURCE\[0\]}\")/lib.sh\"#. \"$ROOT/tests/lib.sh\"#" > "$T/bearings-helpers.sh"
. "$T/bearings-helpers.sh"
show() {  # <label> <env-var-or-empty>
  local home fb json
  home=$(make_home "$1"); write_fixture "$home"; fb=$(make_fakebin "$home"); : > "$home/net.log"
  if [ -n "$2" ]; then json=$(env "$2=1" bash -c '. "$0"; run "$1" "$2" --include-prs --json' "$T/bearings-helpers.sh" "$home" "$fb")
  else json=$(run "$home" "$fb" --include-prs --json); fi
  printf '\n-- %s: gh returned these PR heads:\n' "$1"
  ( PATH="$fb:$PATH" ${2:+env $2=1} gh pr list 2>/dev/null | jq -r '.[] | "  #\(.number)  head=\(.headRefName)"' )
  printf -- '-- task ids this home has a record of (from data/backlog.md, every section):\n'
  sed -n 's/^- \[.\] \([a-z0-9-]*\).*/  \1/p' "$home/data/backlog.md" | sort | tr '\n' ' '; printf '\n'
  printf -- '-- candidate_prs as the captain sees them (num / head-derived task):\n'
  printf '%s' "$json" | jq -r '.candidate_prs[] | "  #\(.num)  task=\(.task)"'
}
show default-feature-head ""
show legacy-fm-head FAKE_GH_LEGACY_BRANCH
show feature-heads-known-and-unknown FAKE_GH_FEATURE_HEADS

# Reviewer-decided boundary: the record check applies to feature/ heads only.
# A legacy fm/<id> head is still labelled even when <id> has no record.
show_custom_gh() {  # <label> <json>
  local home fb json
  home=$(make_home "$1"); write_fixture "$home"; fb=$(make_fakebin "$home"); : > "$home/net.log"
  printf '#!/usr/bin/env bash\necho "gh $*" >> "$NET_LOG"\ncat <<'"'"'JSON'"'"'\n%s\nJSON\n' "$2" > "$fb/gh"; chmod +x "$fb/gh"
  json=$(run "$home" "$fb" --include-prs --json)
  printf '\n-- %s: gh returned these PR heads:\n' "$1"
  ( PATH="$fb:$PATH" gh pr list 2>/dev/null | jq -r '.[] | "  #\(.number)  head=\(.headRefName)"' )
  printf -- '-- task ids this home has a record of (from data/backlog.md, every section):\n'
  sed -n 's/^- \[.\] \([a-z0-9-]*\).*/  \1/p' "$home/data/backlog.md" | sort | tr '\n' ' '; printf '\n'
  printf -- '-- candidate_prs as the captain sees them (num / head-derived task):\n'
  printf '%s' "$json" | jq -r '.candidate_prs[] | "  #\(.num)  task=\(.task)"'
}
show_custom_gh legacy-fm-head-without-record \
  '[{"number":21,"title":"Old lane","url":"https://github.com/kunchenguid/firstmate/pull/21","headRefName":"fm/orphan-lane","reviewDecision":"","mergeable":"MERGEABLE","statusCheckRollup":[]},{"number":22,"title":"Human branch","url":"https://github.com/kunchenguid/firstmate/pull/22","headRefName":"feature/orphan-lane","reviewDecision":"","mergeable":"MERGEABLE","statusCheckRollup":[]},{"number":23,"title":"Bare prefix","url":"https://github.com/kunchenguid/firstmate/pull/23","headRefName":"feature/","reviewDecision":"","mergeable":"MERGEABLE","statusCheckRollup":[]},{"number":24,"title":"Unrelated","url":"https://github.com/kunchenguid/firstmate/pull/24","headRefName":"hotfix/ship-task","reviewDecision":"","mergeable":"MERGEABLE","statusCheckRollup":[]}]'
