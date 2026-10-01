#!/usr/bin/env bash
# Behavior tests for bin/fm-skill-select.sh.
#
# Drives the public argv and environment interface with an isolated HOME,
# FM_HOME, and project clone, and a fake curl on PATH that records argv, the
# request body, the header read from file descriptor 3, and whether the secret
# reached its environment. The fake answers every yes/no question in the
# request it received with the probability FAKE_P assigns to that skill's
# name, so cases set outcomes by skill name. No case touches the network.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TOOL="$ROOT/bin/fm-skill-select.sh"
TMP_ROOT=$(fm_test_tmproot fm-skill-select)
HOME_DIR="$TMP_ROOT/home"
USER_HOME="$TMP_ROOT/user"
PROJECT_DIR="$HOME_DIR/projects/webapp"
FAKEBIN=$(fm_fakebin "$TMP_ROOT")
LOG="$TMP_ROOT/log"
BRIEF="$TMP_ROOT/brief.md"
BASE_BRIEF="$TMP_ROOT/base-brief.md"
RESPONSE_OVERRIDE="$TMP_ROOT/response-override.json"
BASE_PATH=$PATH
KEY='test-key-5a1b-never-on-argv'
mkdir -p "$HOME_DIR/config" "$LOG" "$USER_HOME"

skill() {  # <skills-dir> <dir-name> <frontmatter...>: last arg is the body
  local dir="$1/$2"
  shift 2
  mkdir -p "$dir"
  {
    printf -- '---\n'
    while [ $# -gt 1 ]; do printf '%s\n' "$1"; shift; done
    printf -- '---\n%s\n' "$1"
  } > "$dir/SKILL.md"
}

# User skills for claude (~/.claude/skills) and the agent-compatible root.
skill "$USER_HOME/.claude/skills" typescript 'name: typescript' \
  'description: TypeScript discipline. Use when writing any .ts file.' 'BODY-SENTINEL-typescript'
skill "$USER_HOME/.claude/skills" tdd 'name: tdd' \
  'description: "The red-green loop: use whenever fixing a bug."' 'BODY-SENTINEL-tdd'
skill "$USER_HOME/.claude/skills" grill-me 'name: grill-me' \
  'description: A relentless interview.' 'disable-model-invocation: true' 'BODY-SENTINEL-grill'
skill "$USER_HOME/.claude/skills" no-description 'name: no-description' 'BODY-SENTINEL-nodesc'
skill "$USER_HOME/.claude/skills" shared 'name: shared' \
  'description: The user copy of a shared skill.' 'BODY-SENTINEL-shared-user'
skill "$USER_HOME/.agents/skills" agent-only 'name: agent-only' \
  'description: An agent-compatible user skill.' 'BODY-SENTINEL-agent'
mkdir -p "$USER_HOME/.claude/skills/not-a-skill"
# Project skills in the local clone.
skill "$PROJECT_DIR/.claude/skills" e2e 'name: playwright-e2e' \
  'description: >' '  End-to-end tests in this repo:' '  the docker stack and fixtures.' \
  'license: MIT' 'BODY-SENTINEL-e2e'
skill "$PROJECT_DIR/.claude/skills" shared 'name: shared' \
  'description: The project copy of a shared skill.' 'BODY-SENTINEL-shared-project'
skill "$PROJECT_DIR/.agents/skills" codex-only 'name: codex-only' \
  "description: 'A repo skill for agents, it''s quoted.'" 'BODY-SENTINEL-codex'

cat > "$BASE_BRIEF" <<'MD'
You are a crewmate.

# Task
## Captain's intent
Fix the flaky login end-to-end test.

## Firstmate spec
Reproduce it first.
```
# Not a heading inside a fence
```

# Setup
Setup text that is never sent.

# Rules
1. Rule text.
MD

cat > "$FAKEBIN/curl" <<'SH'
#!/usr/bin/env bash
# Fake curl: records argv (minus the -o target), the stdin body, and the header
# read from fd 3, then answers each skill_N question with FAKE_P[name] (default
# 0.1), or with FAKE_CURL_RESPONSE verbatim when set.
set -u
if [ -n "${TYPESAFE_API_KEY+x}" ] || [ -n "${TYPESAFE_API_KEY_PRIVATE+x}" ]; then
  printf 'curl:secret-present\n' >> "${CHILD_ENV_LOG:?}"
else
  printf 'curl:clean\n' >> "${CHILD_ENV_LOG:?}"
fi
out=''
while [ $# -gt 0 ]; do
  case "$1" in
    -o) out=$2; shift 2 ;;
    *) printf '%s\n' "$1" >> "${FAKE_CURL_LOG:?}/argv"; shift ;;
  esac
done
cat > "$FAKE_CURL_LOG/body"
cat /dev/fd/3 > "$FAKE_CURL_LOG/header" 2>/dev/null || printf 'fd3 unreadable\n' > "$FAKE_CURL_LOG/header"
[ "${FAKE_CURL_FAIL:-0}" = 1 ] && exit 7
if [ -n "${FAKE_CURL_RESPONSE:-}" ]; then
  cp "$FAKE_CURL_RESPONSE" "$out"
else
  p=${FAKE_P:-}
  [ -n "$p" ] || p='{}'
  jq --argjson p "$p" '
    {model: "jev-1.13.0",
     answers: (.questions | with_entries(
       (.value.instructions | capture("load the skill `(?<n>[^`]+)`").n) as $name |
       .value = {type: "noul", noul: ($p[$name] // 0.1)})),
     usage: {input_tokens: 900, output_tokens: 40}}' "$FAKE_CURL_LOG/body" > "$out"
fi
printf '%s' "${FAKE_CURL_HTTP:-200}"
SH
chmod +x "$FAKEBIN/curl"

export FAKE_CURL_LOG="$LOG" CHILD_ENV_LOG="$LOG/child-env"

reset() {
  rm -rf "$LOG"
  mkdir -p "$LOG"
  cp "$BASE_BRIEF" "$BRIEF"
  rm -f "$HOME_DIR/config/dispatch-never-send" "$HOME_DIR/config/claude-account" "$HOME_DIR/.env"
  unset FAKE_CURL_RESPONSE FAKE_CURL_HTTP FAKE_CURL_FAIL FAKE_P
}

# run <exit-var> <out-var> <err-var> [args...]: the tool with fakebin first on
# PATH, an isolated HOME and FM_HOME, and no ambient Claude or Codex root.
run() {
  local __exit=$1 __out=$2 __err=$3 _out _code
  shift 3
  _out=$(env -u CLAUDE_CONFIG_DIR -u CODEX_HOME PATH="$FAKEBIN:$BASE_PATH" HOME="$USER_HOME" \
    FM_HOME="$HOME_DIR" "$TOOL" "$@" 2> "$TMP_ROOT/stderr")
  _code=$?
  printf -v "$__exit" '%s' "$_code"
  printf -v "$__out" '%s' "$_out"
  printf -v "$__err" '%s' "$(cat "$TMP_ROOT/stderr")"
}

code='' out='' err=''
SELECT=("$BRIEF" --project webapp --harness claude)

# --- absent key: off, silent on stdout, no network, brief untouched ----------
reset
unset TYPESAFE_API_KEY
run code out err "${SELECT[@]}" --apply
expect_code 0 "$code" "absent key exits 0"
assert_equals '' "$out" "absent key prints nothing on stdout"
assert_contains "$err" 'skill-select: off (TYPESAFE_API_KEY absent from the environment and' "absent key explains itself"
assert_absent "$LOG/argv" "absent key never calls curl"
cmp -s "$BASE_BRIEF" "$BRIEF" || fail "absent key leaves the brief byte-identical"
pass "absent key is off: one stderr line, exit 0, no network call, brief unchanged"

# --- candidates: harness directories, frontmatter, exclusions, no key --------
reset
run code out err --candidates --project webapp --harness claude
expect_code 0 "$code" "--candidates exits 0"
assert_contains "$out" 'skill-select candidates (4):' "claude sees four usable skills"
assert_contains "$out" "typescript [user] $USER_HOME/.claude/skills/typescript/SKILL.md" "user skills carry absolute paths"
assert_contains "$out" 'playwright-e2e [project] .claude/skills/e2e/SKILL.md' "project skills use the frontmatter name and a worktree path"
assert_contains "$out" "shared [user] $USER_HOME/.claude/skills/shared/SKILL.md" "the user copy wins a duplicate name for claude"
assert_not_contains "$out" 'grill-me' "disable-model-invocation skills are not candidates"
assert_not_contains "$out" 'no-description' "a skill without a description is not a candidate"
assert_not_contains "$out" 'agent-only' "claude does not read ~/.agents/skills"
assert_not_contains "$out" 'codex-only' "claude does not read .agents/skills"
assert_absent "$LOG/argv" "--candidates makes no network call"
run code out err --candidates --project webapp --harness codex
assert_contains "$out" 'skill-select candidates (2):' "codex sees its own directories only"
assert_contains "$out" 'codex-only [project] .agents/skills/codex-only/SKILL.md' "codex reads project .agents/skills"
assert_contains "$out" "agent-only [user] $USER_HOME/.agents/skills/agent-only/SKILL.md" "codex reads ~/.agents/skills"
mkdir -p "$TMP_ROOT/pinned/skills"
skill "$TMP_ROOT/pinned/skills" pinned-only 'name: pinned-only' 'description: Lives in the pinned account root.' 'BODY'
printf '%s\n' "$TMP_ROOT/pinned" > "$HOME_DIR/config/claude-account"
run code out err --candidates --project webapp --harness claude
assert_contains "$out" 'pinned-only [user]' "a pinned Claude account root supplies the user skills"
assert_not_contains "$out" 'typescript [user]' "the pinned root replaces ~/.claude"
pass "candidates follow each harness's directories, frontmatter names, and exclusions"

# --- unsupported harness and empty candidate set are off ---------------------
reset
export TYPESAFE_API_KEY=$KEY
run code out err "${SELECT[@]/claude/pi}" --apply
expect_code 0 "$code" "unsupported harness exits 0"
assert_equals '' "$out" "unsupported harness prints nothing on stdout"
assert_contains "$err" 'skill-select: off (harness pi has no established skill directories' "unsupported harness explains itself"
run code out err "$BRIEF" --project webapp --harness devin --project-dir "$TMP_ROOT/empty-project"
expect_code 2 "$code" "a missing project directory is a usage error"
mkdir -p "$TMP_ROOT/empty-project" "$TMP_ROOT/empty-root"
printf '%s\n' "$TMP_ROOT/empty-root" > "$HOME_DIR/config/claude-account"
run code out err "$BRIEF" --project-dir "$TMP_ROOT/empty-project" --harness claude --apply
assert_contains "$err" 'skill-select: off (no skills available to a claude worker in empty-project' "no candidates is off"
assert_absent "$LOG/argv" "off outcomes never call curl"
cmp -s "$BASE_BRIEF" "$BRIEF" || fail "off outcomes leave the brief unchanged"
pass "unsupported harness and no candidates are off with no network call"

# --- request shape, key handling, and the floor --------------------------------
reset
export FAKE_P='{"typescript": 0.8, "playwright-e2e": 0.97, "tdd": 0.79}'
run code out err "${SELECT[@]}"
expect_code 0 "$code" "select exits 0"
assert_contains "$out" 'status: clear' "a skill at the floor makes a clear result"
assert_contains "$out" 'skill: playwright-e2e p=0.97 -> selected' "most probable first, selected"
assert_contains "$out" 'skill: typescript p=0.8 -> selected' "exactly 0.8 clears the floor"
assert_contains "$out" 'skill: tdd p=0.79 -> below floor' "0.79 is below the floor"
assert_contains "$out" 'skills: playwright-e2e typescript' "the skills line lists the selection"
assert_contains "$out" 'brief: unchanged' "without --apply the brief is not written"
cmp -s "$BASE_BRIEF" "$BRIEF" || fail "select alone leaves the brief byte-identical"
assert_grep 'https://api.typesafe.ai/v1/systemone' "$LOG/argv" "fixed endpoint"
assert_no_grep "$KEY" "$LOG/argv" "the key never appears on curl argv"
assert_equals "Authorization: Bearer $KEY" "$(cat "$LOG/header")" "the key arrives only as the fd 3 header"
assert_grep 'curl:clean' "$CHILD_ENV_LOG" "the key is absent from curl's environment"
body=$(cat "$LOG/body")
assert_equals 'jev-latest' "$(jq -r '.model' <<<"$body")" "fixed model"
assert_equals 'webapp' "$(jq -r '.state.task.project' <<<"$body")" "project is sent"
assert_equals 4 "$(jq '.questions | length' <<<"$body")" "one question per candidate"
assert_equals noul "$(jq -r '[.questions[].type] | unique | join(",")' <<<"$body")" "every question is yes/no"
assert_contains "$(jq -r '.questions[].instructions' <<<"$body")" 'End-to-end tests in this repo: the docker stack and fixtures.' "a folded description is joined"
assert_contains "$(jq -r '.questions[].instructions' <<<"$body")" 'The red-green loop: use whenever fixing a bug.' "a quoted description is unquoted"
assert_not_contains "$body" 'BODY-SENTINEL' "no skill body is ever sent"
assert_not_contains "$body" 'Setup text that is never sent' "only the task sections are sent"
assert_contains "$(jq -r '.state.task.brief' <<<"$body")" 'Fix the flaky login end-to-end test.' "the task sections are sent"
pass "one yes/no question per candidate, key on fd 3 only, floor 0.8 applied in code"

# --- --apply writes the section after # Task, idempotently --------------------
reset
export FAKE_P='{"typescript": 0.9, "playwright-e2e": 0.97}'
run code out err "${SELECT[@]}" --apply
expect_code 0 "$code" "--apply exits 0"
assert_contains "$out" 'brief: written' "--apply reports the write"
expected_section="# Required skills
Load each of these skills before any other task work (after the Setup isolation check), with your tool's skill mechanism or by reading the SKILL.md at the path shown, and follow it throughout this task:
- \`playwright-e2e\` (\`.claude/skills/e2e/SKILL.md\`)
- \`typescript\` (\`$USER_HOME/.claude/skills/typescript/SKILL.md\`)
If one of them cannot be loaded, append \`blocked [at=<epoch>]: required skill <name> cannot be loaded\` and stop.
List the skills you loaded in your final report or PR description."
section=$(awk '/^# Required skills$/{g=1} g&&/^# Setup$/{exit} g' "$BRIEF")
assert_equals "$expected_section"$'\n' "$section"$'\n' "the section lists each skill with its SKILL.md path"
assert_equals '# Task|# Required skills|# Setup|# Rules' "$(grep -E '^# (Task|Required skills|Setup|Rules)$' "$BRIEF" | paste -sd '|' -)" "the section sits directly after # Task, not at the fenced line"
diff <(awk '/^# Required skills$/{skip=1; next} skip&&/^# /{skip=0} !skip' "$BRIEF") "$BASE_BRIEF" >/dev/null \
  || fail "--apply changes nothing outside the section"
export FAKE_P='{"tdd": 0.95}'
run code out err "${SELECT[@]}" --apply
assert_equals 1 "$(grep -c '^# Required skills$' "$BRIEF")" "a second --apply replaces the section"
assert_grep "- \`tdd\`" "$BRIEF" "the replacement lists the new selection"
assert_no_grep "- \`typescript\`" "$BRIEF" "the replacement drops the old selection"
pass "--apply writes one scaffold-placed section and rewrites it in place"

# --- none and error outcomes leave the brief exactly as it was ----------------
cp "$BRIEF" "$TMP_ROOT/with-section.md"
export FAKE_P='{"tdd": 0.5}'
run code out err "${SELECT[@]}" --apply
expect_code 0 "$code" "none exits 0"
assert_contains "$out" 'status: none' "nothing at the floor is none"
assert_contains "$out" 'reason: no skill reached the 0.8 floor' "none explains itself"
assert_not_contains "$out" 'skills:' "none prints no skills line"
assert_contains "$out" 'brief: unchanged' "none does not write"
cmp -s "$TMP_ROOT/with-section.md" "$BRIEF" || fail "none leaves an existing section alone"
export FAKE_CURL_HTTP=500
run code out err "${SELECT[@]}" --apply
expect_code 0 "$code" "http 500 exits 0"
assert_contains "$out" 'status: error' "http 500 is an error outcome"
assert_contains "$out" 'reason: http 500' "http 500 is named"
unset FAKE_CURL_HTTP
export FAKE_CURL_FAIL=1
run code out err "${SELECT[@]}" --apply
assert_contains "$out" 'reason: http 000' "a transport failure is an error outcome"
unset FAKE_CURL_FAIL
printf '%s\n' '{"model": "jev-1.13.0", "answers": {"skill_1": {"type": "noul", "noul": 0.99}}}' > "$RESPONSE_OVERRIDE"
export FAKE_CURL_RESPONSE=$RESPONSE_OVERRIDE
run code out err "${SELECT[@]}" --apply
assert_contains "$out" 'reason: response is not one yes/no answer per skill' "a missing answer is an error outcome"
printf '%s\n' '{"model": "jev-1.13.0", "answers": {"skill_1": {"noul": 1.5}, "skill_2": {"noul": 0.1}, "skill_3": {"noul": 0.1}, "skill_4": {"noul": 0.1}}}' > "$RESPONSE_OVERRIDE"
run code out err "${SELECT[@]}" --apply
assert_contains "$out" 'status: error' "an out-of-range probability is an error outcome"
unset FAKE_CURL_RESPONSE
cmp -s "$TMP_ROOT/with-section.md" "$BRIEF" || fail "error outcomes leave the brief unchanged"
pass "none and error outcomes exit 0 and never touch the brief"

# --- never-send list stops the request ------------------------------------------
reset
printf '%s\n' '# private' 'FLAKY   LOGIN' > "$HOME_DIR/config/dispatch-never-send"
run code out err "${SELECT[@]}" --apply
expect_code 0 "$code" "a never-send match exits 0"
assert_equals '' "$out" "a never-send match prints nothing on stdout"
assert_contains "$err" "skill-select: off (brief text matches $HOME_DIR/config/dispatch-never-send line 2; nothing sent)" "the match names only the line"
assert_not_contains "$err" 'FLAKY' "the listed value is never printed"
assert_absent "$LOG/argv" "a never-send match never calls curl"
cmp -s "$BASE_BRIEF" "$BRIEF" || fail "a never-send match leaves the brief unchanged"
pass "the shared never-send list stops the request before the network"

# --- .env key turns it on -------------------------------------------------------
reset
unset TYPESAFE_API_KEY
printf 'TYPESAFE_API_KEY="%s"\n' "$KEY" > "$HOME_DIR/.env"
run code out err "${SELECT[@]}"
assert_contains "$out" 'status: none' "a .env key turns the tool on"
assert_equals "Authorization: Bearer $KEY" "$(cat "$LOG/header")" "the .env key is sent as the header"
pass "the home .env key turns the tool on"

# --- --set and --clear: firstmate's override, no key, no network ---------------
reset
run code out err "${SELECT[@]}" --set tdd,shared --set playwright-e2e
expect_code 0 "$code" "--set exits 0"
assert_contains "$out" 'skills: playwright-e2e shared tdd' "--set writes exactly the named skills"
assert_grep "- \`shared\` (\`$USER_HOME/.claude/skills/shared/SKILL.md\`)" "$BRIEF" "--set resolves each name to its candidate path"
assert_absent "$LOG/argv" "--set makes no network call"
run code out err "${SELECT[@]}" --set nope
expect_code 2 "$code" "an unknown --set name exits 2"
assert_contains "$err" 'not a skill available to a claude worker in webapp: nope' "an unknown name is named"
run code out err "$BRIEF" --clear
expect_code 0 "$code" "--clear exits 0"
cmp -s "$BASE_BRIEF" "$BRIEF" || fail "--clear restores the brief byte for byte"
pass "--set overrides and --clear removes the section without a key or network"

# --- usage errors ----------------------------------------------------------------
reset
printf 'no task heading\n' > "$TMP_ROOT/free.md"
run code out err "$TMP_ROOT/free.md" --project webapp --harness claude
expect_code 2 "$code" "a brief without # Task exits 2"
assert_contains "$err" 'brief has no # Task section' "the missing heading is named"
run code out err "${SELECT[@]}" --apply --clear
expect_code 2 "$code" "exclusive modes exit 2"
run code out err "$BRIEF" --project webapp
expect_code 2 "$code" "a missing --harness exits 2"
assert_absent "$LOG/argv" "usage errors never call curl"
pass "usage errors exit 2 before any network call"

echo "# all fm-skill-select tests passed"
