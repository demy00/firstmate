#!/usr/bin/env bash
# Behavior tests for bin/fm-skill-usage.sh.
#
# Builds small Claude transcripts under a fixture Claude root and drives the
# public argv and environment interface, asserting the printed table. TZ=UTC
# keeps local-date range membership deterministic.
# shellcheck disable=SC2016 # backticks in fixtures and tables are literal Markdown
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TOOL="$ROOT/bin/fm-skill-usage.sh"
TMP_ROOT=$(fm_test_tmproot fm-skill-usage)
CLAUDE="$TMP_ROOT/claude"
HOME_DIR="$TMP_ROOT/home"
WORKDIR="$TMP_ROOT/cwd"
mkdir -p "$CLAUDE/projects" "$CLAUDE/skills/tdd" "$CLAUDE/skills/expo" "$HOME_DIR/config" "$WORKDIR"
printf -- '---\nname: tdd\n---\n' > "$CLAUDE/skills/tdd/SKILL.md"
printf -- '---\nname: expo\n---\n' > "$CLAUDE/skills/expo/SKILL.md"
export TZ=UTC

transcript() {  # <project-dir> <session> <jsonl-line...>
  local dir="$CLAUDE/projects/$1" file="$CLAUDE/projects/$1/$2.jsonl"
  shift 2
  mkdir -p "$dir"
  printf '%s\n' "$@" > "$file"
}

entry() {  # <type> <timestamp> <cwd> <message-json>
  printf '{"type":"%s","timestamp":"%s","cwd":"%s","message":%s}' "$1" "$2" "$3" "$4"
}

prompt() {  # <json-escaped-text>
  printf '{"role":"user","content":"%s"}' "$1"
}

tool_use() {  # <name> <input-json>
  printf '{"role":"assistant","content":[{"type":"tool_use","id":"t","name":"%s","input":%s}]}' "$1" "$2"
}

WEB=/w/.treehouse/webapp-1a2b/1/webapp
API=/w/.treehouse/api-3c4d/2/api
SHIP_BRIEF='FIRSTMATE_OP: v1 launch-brief: # Task\nYour steering inbox is `/h/state/web-t1.inbox`.\n# Required skills\n- `tdd` (`skills/tdd/SKILL.md`)\n- `typescript` (`skills/typescript/SKILL.md`)\n\n# Definition of done\nDelivery contract: mode=no-mistakes'

# A ship task: the brief arrives as the first prompt, names two skills, and the
# worker loads one of them, no-mistakes, and a plugin skill.
transcript -w-treehouse-webapp-1a2b-1-webapp s1 \
  '{"type":"mode","mode":"normal"}' \
  "$(entry user 2026-10-06T09:00:00Z "$WEB" "$(prompt "$SHIP_BRIEF")")" \
  "$(entry assistant 2026-10-06T09:01:00Z "$WEB" "$(tool_use Skill '{"skill":"tdd"}')")" \
  "$(entry assistant 2026-10-06T09:02:00Z "$WEB" "$(tool_use Skill '{"skill":"anthropic-skills:docx"}')")" \
  "$(entry assistant 2026-10-06T09:03:00Z "$WEB" "$(tool_use Skill '{"skill":"no-mistakes"}')")" \
  '{"type":"user","message":{"role":"user","content":"partial line'
# The same task relaunched: a second transcript naming the same inbox merges
# into one task, adding its Read of a repo skill.
transcript -w-treehouse-webapp-1a2b-1-webapp s2 \
  "$(entry user 2026-10-08T10:00:00Z "$WEB" "$(prompt "$SHIP_BRIEF")")" \
  "$(entry assistant 2026-10-08T10:01:00Z "$WEB" "$(tool_use Read '{"file_path":"/w/.treehouse/webapp-1a2b/1/webapp/.claude/skills/vitest/SKILL.md"}')")"
# A scout: the brief arrives as a line-numbered Read result, with no delivery
# contract, and the worker reads only the lifecycle skill every scout brief names.
transcript -w-treehouse-api-3c4d-2-api s3 \
  "$(entry user 2026-10-07T08:00:00Z "$API" '{"role":"user","content":"read the operational input"}')" \
  "$(entry user 2026-10-07T08:00:01Z "$API" '{"role":"user","content":[{"type":"tool_result","tool_use_id":"t","content":"     1\tFIRSTMATE_OP: v1 launch-brief: # Task\n     2\tSteering inbox `/h/state/api-s1.inbox`.\n     3\t# Definition of done\n     4\tWrite the report."}]}')" \
  "$(entry assistant 2026-10-07T08:01:00Z "$API" "$(tool_use Bash '{"command":"cat /h/.agents/skills/captain-hold-lifecycle/SKILL.md; ls"}')")"
# A ship that loads only no-mistakes, through a slash invocation, plus a shell
# loop whose variable must not read as a skill named "d".
transcript -w-treehouse-api-3c4d-2-api s4 \
  "$(entry user 2026-10-09T08:00:00Z "$API" '{"role":"user","content":"FIRSTMATE_OP: v1 launch-brief: inbox `/h/state/api-t2.inbox`\nDelivery contract: mode=direct-PR"}')" \
  "$(entry user 2026-10-09T08:05:00Z "$API" '{"role":"user","content":[{"type":"text","text":"Base directory for this skill: /u/.claude/skills/no-mistakes\n\n# no-mistakes"}]}')" \
  "$(entry assistant 2026-10-09T08:06:00Z "$API" "$(tool_use Bash '{"command":"for d in a b; do head -3 $d/SKILL.md; done"}')")"
# Outside every tested week: a task started on 2026-10-13, whose task text
# mentions another task's inbox before the scaffold's own inbox line.
transcript -w-treehouse-api-3c4d-2-api s5 \
  "$(entry user 2026-10-13T08:00:00Z "$API" '{"role":"user","content":"FIRSTMATE_OP: v1 launch-brief: # Task\nFollow up on /h/state/web-t1.inbox.\n# Firstmate instruction inbox\nFirstmate steers you through durable message files in '"'"'/h/state/api-later.inbox'"'"'."}')" \
  "$(entry assistant 2026-10-13T08:01:00Z "$API" "$(tool_use Skill '{"skill":"ui-design"}')")"
# Not worker tasks: a treehouse session with no launch brief, and a session
# outside the treehouse transcript directories.
transcript -w-treehouse-api-3c4d-2-api s6 \
  "$(entry user 2026-10-07T08:00:00Z "$API" '{"role":"user","content":"hello"}')" \
  "$(entry assistant 2026-10-07T08:01:00Z "$API" "$(tool_use Skill '{"skill":"shadcn"}')")"
transcript -Users-me-firstmate s7 \
  "$(entry user 2026-10-07T08:00:00Z /Users/me/firstmate '{"role":"user","content":"FIRSTMATE_OP: v1 launch-brief: inbox `/h/state/elsewhere.inbox`"}')" \
  "$(entry assistant 2026-10-07T08:01:00Z /Users/me/firstmate "$(tool_use Skill '{"skill":"shadcn"}')")"

WEEK_TABLE='## Skill usage 2026-10-05..2026-10-11

3 worker tasks started (api 2, webapp 1); 1 had a `# Required skills` section.

| Skill | Tasks | Named in brief | By repo |
|---|---|---|---|
| `no-mistakes` | 2 | 0 | api 1, webapp 1 |
| `captain-hold-lifecycle` | 1 | 0 | api 1 |
| `docx` | 1 | 0 | webapp 1 |
| `tdd` | 1 | 1 | webapp 1 |
| `vitest` | 1 | 0 | webapp 1 |
| `typescript` | 0 | 1 | - |

Named in the brief but not loaded: `typescript` (web-t1).

No skill beyond `no-mistakes` and `captain-hold-lifecycle`: 2 of 3 tasks (1 of 2 ship tasks).
- api: api-s1 (scout), api-t2

Installed skills no task loaded: `expo`.'

run() {  # <code-var> <out-var> <err-var> <args...>
  local __code=$1 __out=$2 __err=$3 __o __e __c
  shift 3
  __o=$(cd "$WORKDIR" && FM_HOME="$HOME_DIR" "$TOOL" "$@" 2>"$TMP_ROOT/stderr")
  __c=$?
  __e=$(cat "$TMP_ROOT/stderr")
  printf -v "$__code" '%s' "$__c"
  printf -v "$__out" '%s' "$__o"
  printf -v "$__err" '%s' "$__e"
}

code='' out='' err=''

# --- the weekly table ------------------------------------------------------------
before=$(cd "$CLAUDE" && find . -type f -exec cksum {} + | sort)
run code out err --week 2026-W41 --claude-root "$CLAUDE"
expect_code 0 "$code" "--week prints the table"
assert_equals "$WEEK_TABLE" "$out" "the weekly table counts each task once, by repo, with brief names and bare tasks"
assert_equals "" "$err" "a clean run prints nothing on stderr"
pass "the weekly table merges relaunches, normalizes loads, and ignores non-worker sessions"

run code out err --since 2026-10-05 --until 2026-10-11 --claude-root "$CLAUDE"
assert_equals "$WEEK_TABLE" "$out" "an explicit date range matches the ISO week"
pass "--since/--until is an inclusive local-date range"

run code out err --since 2026-10-13 --until 2026-10-13 --claude-root "$CLAUDE"
assert_contains "$out" '| `ui-design` | 1 | 0 | api 1 |' "a task counts in the range its first message falls in"
assert_not_contains "$out" 'webapp' "earlier tasks stay out of a later range"
assert_contains "$out" '1 worker tasks started (api 1)' "a task naming another task's inbox keeps its own id"
run code out err --week 2026-W30 --claude-root "$CLAUDE"
assert_equals $'## Skill usage 2026-07-20..2026-07-26\n\nNo worker tasks started in this range.' "$out" "an empty range says so"
pass "range membership follows each task's first message"

after=$(cd "$CLAUDE" && find . -type f -exec cksum {} + | sort)
assert_equals "$before" "$after" "the Claude root is unchanged"
assert_equals "" "$(ls -A "$WORKDIR")" "nothing is written to the working directory"
pass "the tool is read-only"

# --- which Claude root -----------------------------------------------------------
CLAUDE_CONFIG_DIR="$CLAUDE" run code out err --week 2026-W41
assert_equals "$WEEK_TABLE" "$out" "CLAUDE_CONFIG_DIR is the default root"
mkdir -p "$TMP_ROOT/empty/projects"
printf '%s\n' "$CLAUDE" > "$HOME_DIR/config/claude-account"
CLAUDE_CONFIG_DIR="$TMP_ROOT/empty" run code out err --week 2026-W41
assert_equals "$WEEK_TABLE" "$out" "the pinned worker account root wins over CLAUDE_CONFIG_DIR"
printf '%s\n' "$TMP_ROOT/missing" > "$HOME_DIR/config/claude-account"
run code out err --week 2026-W41
expect_code 2 "$code" "an unresolvable worker account pin exits 2"
assert_contains "$err" 'config/claude-account does not resolve' "the pin error is named"
rm -f "$HOME_DIR/config/claude-account"
pass "the default root is the one workers launch under"

# --- usage errors ----------------------------------------------------------------
run code out err --week 2026-W41 --since 2026-10-05 --until 2026-10-11 --claude-root "$CLAUDE"
expect_code 2 "$code" "--week with --since/--until exits 2"
run code out err --since 2026-10-05 --claude-root "$CLAUDE"
expect_code 2 "$code" "--since without --until exits 2"
run code out err --since 2026-10-11 --until 2026-10-05 --claude-root "$CLAUDE"
expect_code 2 "$code" "a reversed range exits 2"
run code out err --week 2026-41 --claude-root "$CLAUDE"
expect_code 2 "$code" "a malformed week exits 2"
assert_contains "$err" 'not a YYYY-Www ISO week' "the malformed week is named"
run code out err --claude-root "$TMP_ROOT/missing"
expect_code 2 "$code" "a missing Claude root exits 2"
assert_equals "" "$out" "usage errors print no table"
pass "usage errors exit 2"

run code out err --help
expect_code 0 "$code" "--help exits 0"
assert_contains "$out" 'fm-skill-usage.sh [--week YYYY-Www' "--help prints the usage"
pass "--help prints the header"

echo "# all fm-skill-usage tests passed"
