#!/usr/bin/env bash
# Behavior tests for bin/fm-spawn-preflight.sh and its use by bin/fm-spawn.sh.
#
# A brief declares the shared machine resources its task needs in an optional
# `# Needs` section, and the spawn refuses with one blocker line naming every
# missing one before anything is created. Cases drive the preflight's argv
# interface against briefs written here, with PATH fakes for `docker` and
# `pgrep` so no case touches a real Docker engine or process table, and drive
# fm-spawn.sh with a refusing fake `tmux` so no endpoint or worktree is made.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TOOL="$ROOT/bin/fm-spawn-preflight.sh"
SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-spawn-preflight)
FAKEBIN=$(fm_fakebin "$TMP_ROOT")
DOCKER_DIR="$TMP_ROOT/docker"
BRIEF="$TMP_ROOT/brief.md"
ABSENT_TOOL=fm-preflight-absent-tool-zz
BASE_PATH=$PATH
mkdir -p "$DOCKER_DIR"

# A fake docker: `info` answers by FAKE_DOCKER_UP, `run ... df -Pk /` reports
# FAKE_DOCKER_FREE_KB free, and `network create` succeeds FAKE_DOCKER_NET_ROOM
# times before refusing like an exhausted address pool. Live networks are kept
# in $DOCKER_DIR/live so a case can see what the preflight left behind.
cat > "$FAKEBIN/docker" <<'SH'
#!/usr/bin/env bash
dir=$FAKE_DOCKER_DIR
printf '%s\n' "$*" >> "$dir/calls"
[ "${FAKE_DOCKER_UP:-1}" = 1 ] || { echo "Cannot connect to the Docker daemon" >&2; exit 1; }
case "$1" in
info) exit 0 ;;
run)
  printf 'Filesystem 1024-blocks Used Available Capacity Mounted on\n'
  printf 'overlay 104857600 1 %s 50%% /\n' "$FAKE_DOCKER_FREE_KB"
  ;;
network)
  case "$2" in
  create)
    made=$(cat "$dir/made" 2>/dev/null || echo 0)
    if [ "$made" -ge "${FAKE_DOCKER_NET_ROOM:-0}" ]; then
      echo "Error response from daemon: all predefined address pools have been fully subnetted" >&2
      exit 1
    fi
    echo $((made + 1)) > "$dir/made"
    for name; do :; done
    printf '%s\n' "$name" >> "$dir/live"
    echo "net-$name"
    ;;
  rm)
    shift 2
    for name; do
      grep -vxF -- "$name" "$dir/live" > "$dir/live.tmp" || true
      mv "$dir/live.tmp" "$dir/live"
      printf '%s\n' "$name"
    done
    ;;
  esac
  ;;
esac
SH
# A fake pgrep: `pgrep -x <name>` matches only the names in FAKE_APPS.
cat > "$FAKEBIN/pgrep" <<'SH'
#!/usr/bin/env bash
for name; do :; done
case ":${FAKE_APPS:-}:" in
*":$name:"*) echo 4242 ;;
*) exit 1 ;;
esac
SH
chmod +x "$FAKEBIN/docker" "$FAKEBIN/pgrep"

reset_docker() {
  rm -f "$DOCKER_DIR/calls" "$DOCKER_DIR/made" "$DOCKER_DIR/live"
  : > "$DOCKER_DIR/live"
}

needs_brief() {  # <need-line>...: a brief whose # Needs section holds these lines
  {
    printf 'You are a crewmate.\n\n# Task\n## Captain'\''s intent\nShip it.\n\n## Firstmate spec\nBuild it.\n\n# Needs\n'
    printf '%s\n' "$@"
    printf '\n# Definition of done\nCommit it.\n'
  } > "$BRIEF"
}

run() {  # <code-var> <err-var> <env-assignment>... -- <tool-args>...
  local __code=$1 __err=$2 _code
  local -a envs=()
  shift 2
  while [ "$#" -gt 0 ] && [ "$1" != -- ]; do envs+=("$1"); shift; done
  shift
  env PATH="$FAKEBIN:$BASE_PATH" FAKE_DOCKER_DIR="$DOCKER_DIR" ${envs[@]+"${envs[@]}"} \
    "$TOOL" "$@" > "$TMP_ROOT/stdout" 2> "$TMP_ROOT/stderr"
  _code=$?
  printf -v "$__code" '%s' "$_code"
  printf -v "$__err" '%s' "$(cat "$TMP_ROOT/stdout" "$TMP_ROOT/stderr")"
}

code='' out=''

# --- nothing declared --------------------------------------------------------
reset_docker
printf 'You are a crewmate.\n\n# Task\nShip it.\n\n# Definition of done\nCommit it.\n' > "$BRIEF"
run code out -- "$BRIEF"
expect_code 0 "$code" "a brief without # Needs"
assert_equals "" "$out" "a brief without # Needs prints nothing"
assert_absent "$DOCKER_DIR/calls" "a brief without # Needs never touches docker"
cat > "$BRIEF" <<'EOF'
# Task
Example of the format, not a declaration:

```markdown
# Needs
- tool: fm-preflight-absent-tool-zz
```

# Definition of done
EOF
run code out -- "$BRIEF"
expect_code 0 "$code" "a fenced # Needs example is not a declaration"
pass "a task that declares no needs gets no checks"

# --- tools, environment, files, apps ---------------------------------------
reset_docker
needs_brief "- tool: sh" "- tool: $ABSENT_TOOL"
run code out -- "$BRIEF"
expect_code 1 "$code" "a missing tool"
assert_contains "$out" "tool $ABSENT_TOOL is not on PATH" "the missing tool is named"
assert_not_contains "$out" "tool sh " "a present tool is not reported"
needs_brief "- tool: sh"
run code out -- "$BRIEF"
expect_code 0 "$code" "a present tool"
assert_equals "" "$out" "a satisfied preflight prints nothing"
pass "tool needs refuse only for a command missing from PATH"

needs_brief "- env: FM_PREFLIGHT_SET" "- env: FM_PREFLIGHT_UNSET" "- env: FM_PREFLIGHT_EMPTY"
run code out FM_PREFLIGHT_SET=yes FM_PREFLIGHT_EMPTY= -- "$BRIEF"
expect_code 1 "$code" "an unset environment variable"
assert_contains "$out" "environment variable FM_PREFLIGHT_UNSET is not set" "the unset variable is named"
assert_contains "$out" "environment variable FM_PREFLIGHT_EMPTY is not set" "an empty variable counts as unset"
assert_not_contains "$out" "FM_PREFLIGHT_SET " "a set variable is not reported"
pass "env needs refuse for an unset or empty variable"

CRED="$TMP_ROOT/demo-env"
printf '# demo\nexport OPENROUTER_API_KEY="s3cr3t-value"\nEMPTY_KEY=\nQUOTED_EMPTY=""\n' > "$CRED"
needs_brief "- env: OPENROUTER_API_KEY from $CRED" "- env: EMPTY_KEY from $CRED" \
  "- env: QUOTED_EMPTY from $CRED" "- env: ABSENT_KEY from $CRED" \
  "- env: ANY_KEY from $TMP_ROOT/no-such-env"
run code out -- "$BRIEF"
expect_code 1 "$code" "credentials missing from an env file"
assert_contains "$out" "EMPTY_KEY is not set in $CRED" "an empty assignment is missing"
assert_contains "$out" "QUOTED_EMPTY is not set in $CRED" "a quoted empty assignment is missing"
assert_contains "$out" "ABSENT_KEY is not set in $CRED" "an absent key is missing"
assert_contains "$out" "$TMP_ROOT/no-such-env is not readable" "an unreadable env file is named"
assert_not_contains "$out" "OPENROUTER_API_KEY" "a present credential is not reported"
assert_not_contains "$out" "s3cr3t-value" "a credential value is never printed"
needs_brief "- env: OPENROUTER_API_KEY from $CRED"
run code out -- "$BRIEF"
expect_code 0 "$code" "a credential present in its env file"
pass "env-file needs check the named key is assigned without printing its value"

printf 'key material\n' > "$TMP_ROOT/key.json"
: > "$TMP_ROOT/empty.json"
needs_brief "- file: $TMP_ROOT/key.json" "- file: $TMP_ROOT/empty.json" "- file: $TMP_ROOT/none.json"
run code out -- "$BRIEF"
expect_code 1 "$code" "missing credential files"
assert_contains "$out" "file $TMP_ROOT/empty.json is missing or empty" "an empty file is missing"
assert_contains "$out" "file $TMP_ROOT/none.json is missing or empty" "an absent file is missing"
assert_not_contains "$out" "key.json" "a present file is not reported"
mkdir -p "$TMP_ROOT/home"
printf 'x\n' > "$TMP_ROOT/home/token"
needs_brief "- file: ~/token"
run code out HOME="$TMP_ROOT/home" -- "$BRIEF"
expect_code 0 "$code" "a ~ path resolves against HOME"
pass "file needs refuse for a missing or empty file"

needs_brief "- app: Paper" "- app: Figma"
run code out FAKE_APPS=Paper -- "$BRIEF"
expect_code 1 "$code" "an app that is not running"
assert_contains "$out" "app Figma is not running" "the stopped app is named"
assert_not_contains "$out" "app Paper" "a running app is not reported"
pass "app needs refuse for a process that is not running"

# --- Docker ------------------------------------------------------------------
reset_docker
needs_brief "- docker-disk: 12G"
run code out FAKE_DOCKER_FREE_KB=11219763 -- "$BRIEF"
expect_code 1 "$code" "too little Docker disk"
assert_contains "$out" "Docker disk has 10.7G free, the task needs 12G" "free and needed disk are named"
run code out FAKE_DOCKER_FREE_KB=22020096 -- "$BRIEF"
expect_code 0 "$code" "enough Docker disk"
needs_brief "- docker-disk: 500M"
run code out FAKE_DOCKER_FREE_KB=600000 -- "$BRIEF"
expect_code 0 "$code" "a megabyte need"
pass "docker-disk needs compare free space inside Docker with the declared size"

reset_docker
needs_brief "- docker-networks: 2"
run code out FAKE_DOCKER_NET_ROOM=1 -- "$BRIEF"
expect_code 1 "$code" "an exhausted Docker network pool"
assert_contains "$out" "only 1 of 2 new Docker networks can be created" "the network shortfall is named"
assert_equals "" "$(cat "$DOCKER_DIR/live")" "the probe left a network behind after a refusal"
reset_docker
run code out FAKE_DOCKER_NET_ROOM=5 -- "$BRIEF"
expect_code 0 "$code" "room for the declared networks"
assert_equals "" "$(cat "$DOCKER_DIR/live")" "the probe left a network behind after a pass"
pass "docker-networks needs prove the networks can be created and leave none behind"

reset_docker
needs_brief "- docker-disk: 12G" "- docker-networks: 1" "- tool: sh"
run code out FAKE_DOCKER_UP=0 -- "$BRIEF"
expect_code 1 "$code" "Docker not running"
assert_contains "$out" "Docker is not running" "a stopped Docker engine is named"
assert_not_contains "$out" "Docker disk has" "no disk figure is invented when Docker is down"
pass "Docker needs refuse when the engine is unreachable"

# --- one blocker line ---------------------------------------------------------
reset_docker
needs_brief "- tool: $ABSENT_TOOL" "- env: FM_PREFLIGHT_UNSET" "- app: Paper" "- docker-disk: 12G"
run code out FAKE_DOCKER_FREE_KB=1048576 -- "$BRIEF"
expect_code 1 "$code" "several missing needs"
assert_equals 1 "$(printf '%s\n' "$out" | grep -c .)" "several missing needs are reported on one line"
for item in "tool $ABSENT_TOOL" FM_PREFLIGHT_UNSET "app Paper" "Docker disk has 1.0G free"; do
  assert_contains "$out" "$item" "the blocker line names every missing need"
done
assert_contains "$out" "$BRIEF" "the blocker line names the brief"
pass "every missing need is named on one blocker line"

# --- malformed declarations ---------------------------------------------------
for line in "- tools: cargo" "- docker-disk: 12" "- docker-disk: lots" "- docker-networks: 0" \
  "- env: 9BAD" "- env: KEY from" "- tool:" "cargo" "- app: "; do
  reset_docker
  needs_brief "- tool: sh" "$line"
  run code out -- "$BRIEF"
  expect_code 2 "$code" "malformed need '$line'"
  assert_contains "$out" "# Needs" "a malformed need names the section"
  assert_contains "$out" "${line#- }" "a malformed need quotes the bad line"
done
reset_docker
needs_brief "- tool: $ABSENT_TOOL" "- docker-disk: twelve"
run code out -- "$BRIEF"
expect_code 2 "$code" "a malformed need beside a missing one"
assert_absent "$DOCKER_DIR/calls" "a malformed declaration runs no checks"
run code out -- "$TMP_ROOT/no-such-brief.md"
expect_code 2 "$code" "a missing brief"
run code out --
expect_code 2 "$code" "no brief argument"
run code out -- --help
expect_code 0 "$code" "--help"
assert_contains "$out" "# Needs" "--help documents the section"
pass "a malformed declaration exits 2 naming the line, before any check runs"

# --- fm-spawn runs the preflight before anything is created --------------------
SPAWN_HOME="$TMP_ROOT/spawn/home"
SPAWN_PROJ="$TMP_ROOT/spawn/projects/proj"
SPAWN_BIN="$TMP_ROOT/spawn/bin"
mkdir -p "$SPAWN_HOME/data" "$SPAWN_HOME/state" "$SPAWN_HOME/config" "$SPAWN_PROJ" "$SPAWN_BIN"
git -C "$SPAWN_PROJ" init -q || fail "could not initialize project fixture"
cat > "$SPAWN_BIN/tmux" <<SH
#!/bin/sh
printf '%s\n' "\$*" >> "$TMP_ROOT/spawn/tmux-calls"
exit 1
SH
chmod +x "$SPAWN_BIN/tmux"

spawn_brief() {  # <id> <needs-line>...
  local id=$1
  shift
  mkdir -p "$SPAWN_HOME/data/$id"
  {
    printf 'You are a crewmate.\n\n# Task\n## Captain'\''s intent\nShip it.\n\n## Firstmate spec\nBuild it.\n\n'
    if [ "$#" -gt 0 ]; then
      printf '# Needs\n'
      printf '%s\n' "$@"
      printf '\n'
    fi
    printf '# Definition of done\nDelivery contract: mode=no-mistakes\n'
  } > "$SPAWN_HOME/data/$id/brief.md"
}

run_spawn() {  # <spawn-args...>
  FM_ROOT_OVERRIDE='' FM_HOME="$SPAWN_HOME" \
    FM_STATE_OVERRIDE="$SPAWN_HOME/state" FM_DATA_OVERRIDE="$SPAWN_HOME/data" \
    FM_PROJECTS_OVERRIDE="$TMP_ROOT/projects-unused" FM_CONFIG_OVERRIDE="$SPAWN_HOME/config" \
    FM_SPAWN_NO_GUARD=1 FM_BACKEND=tmux PATH="$SPAWN_BIN:$FAKEBIN:$BASE_PATH" \
    "$SPAWN" "$@" 2>&1
}

spawn_brief needs-ship "- tool: $ABSENT_TOOL"
rm -f "$TMP_ROOT/spawn/tmux-calls"
out=$(run_spawn needs-ship "$SPAWN_PROJ" claude --mode no-mistakes --yolo off)
code=$?
[ "$code" -ne 0 ] || fail "a ship spawn with a missing need should exit non-zero"
assert_contains "$out" "tool $ABSENT_TOOL is not on PATH" "the ship spawn names the missing need"
assert_absent "$SPAWN_HOME/state/needs-ship.meta" "a refused ship spawn wrote task metadata"
assert_absent "$TMP_ROOT/spawn/tmux-calls" "a refused ship spawn reached the session provider"

spawn_brief needs-scout "- tool: $ABSENT_TOOL"
out=$(run_spawn needs-scout "$SPAWN_PROJ" claude --scout)
code=$?
[ "$code" -ne 0 ] || fail "a scout spawn with a missing need should exit non-zero"
assert_contains "$out" "tool $ABSENT_TOOL is not on PATH" "the scout spawn names the missing need"
assert_absent "$TMP_ROOT/spawn/tmux-calls" "a refused scout spawn reached the session provider"

spawn_brief needs-bad "- tools: cargo"
out=$(run_spawn needs-bad "$SPAWN_PROJ" claude --mode no-mistakes --yolo off)
code=$?
[ "$code" -ne 0 ] || fail "a spawn with a malformed need should exit non-zero"
assert_contains "$out" "tools: cargo" "the spawn names the malformed need"
assert_absent "$TMP_ROOT/spawn/tmux-calls" "a malformed declaration reached the session provider"

spawn_brief needs-met "- tool: sh"
out=$(run_spawn needs-met "$SPAWN_PROJ" claude --mode no-mistakes --yolo off)
assert_not_contains "$out" "spawn preflight" "a satisfied preflight refused the spawn"
assert_present "$TMP_ROOT/spawn/tmux-calls" "a satisfied preflight did not let the spawn reach the session provider"
rm -f "$TMP_ROOT/spawn/tmux-calls"
spawn_brief needs-none
out=$(run_spawn needs-none "$SPAWN_PROJ" claude --mode no-mistakes --yolo off)
assert_not_contains "$out" "spawn preflight" "a brief without needs was refused by the preflight"
assert_present "$TMP_ROOT/spawn/tmux-calls" "a brief without needs did not reach the session provider"
pass "fm-spawn refuses a missing or malformed need before any endpoint exists"

echo "# all fm-spawn-preflight tests passed"
