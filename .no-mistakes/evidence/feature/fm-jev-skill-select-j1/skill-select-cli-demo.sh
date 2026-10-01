#!/usr/bin/env bash
# Offline end-user demo of bin/fm-skill-select.sh (no key, no network).
# Usage: skill-select-cli-demo.sh <worktree>
W=$1
T=$(mktemp -d)
mkdir -p "$T/home/.claude/skills/shadcn" "$T/home/.claude/skills/tdd" "$T/fm/projects/web/.claude/skills/vitest" "$T/fm/config"
printf -- '---\nname: shadcn\ndescription: Build with shadcn/ui components and theme tokens.\n---\nbody\n' > "$T/home/.claude/skills/shadcn/SKILL.md"
printf -- '---\nname: tdd\ndescription: Red-green loop for implementing a spec.\n---\nbody\n' > "$T/home/.claude/skills/tdd/SKILL.md"
printf -- '---\nname: vitest\ndescription: Unit tests with vitest.\n---\nbody\n' > "$T/fm/projects/web/.claude/skills/vitest/SKILL.md"
printf '# Task\nAdd a settings dialog with shadcn components and tests.\n\n# Definition of done\n- tests pass\n' > "$T/brief.md"
cp "$T/brief.md" "$T/brief.orig"
export HOME=$T/home FM_HOME=$T/fm
unset TYPESAFE_API_KEY CLAUDE_CONFIG_DIR
S=$W/bin/fm-skill-select.sh
run() { echo "\$ fm-skill-select.sh ${*:2}"; "$@" 2>&1 | sed "s#$T#<tmp>#g"; echo "[exit ${PIPESTATUS[0]}]"; echo; }
run "$S" --candidates --project web --harness claude
run "$S" "$T/brief.md" --project web --harness claude --apply
run "$S" "$T/brief.md" --project web --harness claude --set shadcn,vitest
echo '$ cat brief.md'; cat "$T/brief.md"; echo
run "$S" "$T/brief.md" --project web --harness claude --set nosuch
run "$S" "$T/brief.md" --clear
echo '$ cmp brief.md brief.orig'; cmp "$T/brief.md" "$T/brief.orig" && echo identical; echo
echo "$T/fm/missing-account" > "$T/fm/config/claude-account"
run "$S" --candidates --project web --harness claude
