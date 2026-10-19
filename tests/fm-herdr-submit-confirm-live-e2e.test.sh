#!/usr/bin/env bash
# Live Herdr submit-confirmation guard (live-harness-optin family).
#
# Herdr's native agent_status can stay idle for a whole landed Claude turn, and
# a busy-queued Enter can keep proven pending text visible. A stub cannot prove
# either signal. This guard launches real Claude Code in an isolated Herdr lab
# and requires fm_backend_herdr_send_text_submit to report empty for a landed
# idle steer. It then steers the worker through the real fm-send in the lab's
# default-size pane, where the steering doorbell wraps past the rows Claude's
# composer shows, and requires the worker to act on and acknowledge the inbox
# record (the 2026-10-19 doorbell miss: the scrolled composer read as a lost
# head and every doorbell was cleared unsent). Last, it requires the same
# submit path to prove and submit a typed /exit slash command behind the
# command popup Claude renders below the composer (the fm-control exit breakage
# on 2.1.283) and verifies the agent actually exited. It fails naming the harness and version rather than
# degrading quietly.
#
# Run explicitly with FM_HERDR_SUBMIT_CONFIRM_LIVE=1 after a Herdr or Claude
# upgrade, and before trusting a refreshed docs/verification/runtime-backends.md
# "Herdr submit confirmation" entry.
# Every Herdr call, including adapter calls, is routed through bin/fm-herdr-lab.sh.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LAB_HELPER=${HERDR_LAB_HELPER:-$ROOT/bin/fm-herdr-lab.sh}

fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }

fm_live_gate opt-in FM_HERDR_SUBMIT_CONFIRM_LIVE herdr jq claude

[ -x "$LAB_HELPER" ] || fail "FM_HERDR_SUBMIT_CONFIRM_LIVE=1 but the Herdr lab helper is not executable at $LAB_HELPER"

# shellcheck source=tests/herdr-test-safety.sh
. "$ROOT/tests/herdr-test-safety.sh"
herdr_forget_inherited_pane

ORIGINAL_PATH=$PATH
SESSION=$("$LAB_HELPER" name herdr-submit-confirm-live)
TMP_ROOT=$(mktemp -d "$(cd "${TMPDIR:-/tmp}" && pwd -P)/fm-herdr-submit-confirm-live.XXXXXX")
FAKEBIN="$TMP_ROOT/fakebin"
mkdir -p "$FAKEBIN"
CHECKED=0

cleanup() {
  local rc=$?
  trap - EXIT
  if ! PATH="$ORIGINAL_PATH" "$LAB_HELPER" teardown "$SESSION"; then
    rc=1
  fi
  rm -rf "$TMP_ROOT"
  exit "$rc"
}
trap cleanup EXIT

cat > "$FAKEBIN/herdr" <<EOF
#!/usr/bin/env bash
set -u
args=("\$@")
n=\${#args[@]}
if [ "\$n" -ge 2 ] && [ "\${args[\$((n-2))]}" = --session ]; then
  [ "\${args[\$((n-1))]}" = "$SESSION" ] || { echo "wrapper refused foreign session" >&2; exit 97; }
  args=("\${args[@]:0:\$((n-2))}")
else
  echo "wrapper requires trailing --session $SESSION" >&2
  exit 98
fi
exec env PATH="$ORIGINAL_PATH" "$LAB_HELPER" run "$SESSION" "\${args[@]}"
EOF
chmod +x "$FAKEBIN/herdr"

"$LAB_HELPER" provision "$SESSION" || fail "could not provision the isolated Herdr lab"
export PATH="$FAKEBIN:$ORIGINAL_PATH"

# shellcheck source=/dev/null
. "$ROOT/bin/backends/herdr.sh"

lab() { env PATH="$ORIGINAL_PATH" "$LAB_HELPER" run "$SESSION" "$@"; }
WS_JSON=$(lab workspace create --cwd "$ROOT" --label fm-submitlive --no-focus) \
  || fail "could not create the isolated submit-confirm workspace"
PANE=$(printf '%s' "$WS_JSON" | jq -er '.result.root_pane.pane_id') \
  || fail "workspace create did not return a pane id"
WS_ID=$(printf '%s' "$WS_JSON" | jq -er '.result.workspace.workspace_id') \
  || fail "workspace create did not return a workspace id"
TAB_ID=$(printf '%s' "$WS_JSON" | jq -er '.result.tab.tab_id') \
  || fail "workspace create did not return a tab id"
TARGET="$SESSION:$PANE"
VERSION=$(PATH="$ORIGINAL_PATH" claude --version 2>/dev/null | head -1 || printf 'version-unknown')
HERDR_VER=$(PATH="$ORIGINAL_PATH" herdr --version 2>/dev/null | head -1 || printf 'herdr-unknown')

# --add-dir grants the steering inbox under TMP_ROOT the way fm-spawn grants a
# worker its task channels.
lab pane run "$PANE" "CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false CLAUDE_CODE_SEND_FEEDBACK=0 claude --dangerously-skip-permissions --add-dir '$TMP_ROOT' --settings '{\"feedbackDrafts\":\"off\"}'" >/dev/null \
  || fail "could not launch Claude Code ($VERSION) in the isolated Herdr pane"

idle=0
trusted=0
i=0
while [ "$i" -lt 60 ]; do
  screen=$(lab pane read "$PANE" --source visible 2>/dev/null || true)
  case "$screen" in
    *'bypass permissions on'*)
      # The composer footer means Claude is past any folder-trust prompt. Herdr
      # can report the agent idle while that prompt is still up, so the wait
      # keys off the rendered composer rather than the native status alone.
      st=$(lab agent get "$PANE" 2>/dev/null | jq -r '.result.agent.agent_status // empty')
      case "$st" in idle|done) idle=1; break ;; esac
      ;;
    *'Yes, I trust this folder'*)
      # A fresh checkout path stops on Claude's folder-trust prompt, which the
      # pre-send proof would read as a non-empty composer. Accept it once and
      # keep waiting for a real idle composer; the accepted dialog stays in the
      # viewport. The prompt preselects "No, exit", so move to "Yes" before
      # confirming; a bare Enter quits Claude.
      if [ "$trusted" = 0 ]; then
        trusted=1
        lab pane send-keys "$PANE" down enter >/dev/null \
          || fail "could not accept Claude's folder-trust prompt"
      fi
      ;;
  esac
  i=$((i + 1))
  sleep 1
done
[ "$idle" = 1 ] || fail "Claude Code ($VERSION) on $HERDR_VER never rendered an idle composer in the lab pane"

TOKEN="FMHERDRPONG$$_$RANDOM"
verdict=$(fm_backend_herdr_send_text_submit "$TARGET" "Reply with exactly $TOKEN and nothing else." 3 0.4 0.4) \
  || fail "send_text_submit failed to run against Claude Code ($VERSION) on $HERDR_VER"
CHECKED=1
[ "$verdict" = empty ] \
  || fail "Claude Code ($VERSION) on $HERDR_VER: a landed idle steer must confirm empty, got '$verdict'"

# Confirm the instruction reached Claude, not merely that the composer cleared.
# The token occurs once in the submitted prompt and once in Claude's reply.
landed=0
i=0
screen=''
while [ "$i" -lt 45 ]; do
  screen=$(lab pane read "$PANE" --source recent --lines 200 2>/dev/null || true)
  occurrences=$(printf '%s\n' "$screen" | grep -F -c "$TOKEN" || true)
  if [ "$occurrences" -ge 2 ]; then
    landed=1
    break
  fi
  i=$((i + 1))
  sleep 1
done
[ "$landed" = 1 ] \
  || fail "Claude Code ($VERSION) on $HERDR_VER: submit reported '$verdict' but the expected reply never rendered"
pass "live Herdr submit confirm: Claude Code ($VERSION) on $HERDR_VER reports empty and renders the requested reply in isolated session $SESSION"

# Away-mode digests start with U+2063, which Claude's composer read-back drops.
# The pre-Enter proof must still accept the rest of the payload.
# shellcheck source=bin/fm-operational-input.sh
. "$ROOT/bin/fm-operational-input.sh"
# wait_idle: up to 45 seconds for the lab Claude to report idle or done.
wait_idle() {
  local i=0 st
  while [ "$i" -lt 45 ]; do
    st=$(lab agent get "$PANE" 2>/dev/null | jq -r '.result.agent.agent_status // empty')
    case "$st" in idle|done) return 0 ;; esac
    i=$((i + 1))
    sleep 1
  done
  return 1
}
wait_idle || true
OP_TOKEN="FMHERDROPPONG$$_$RANDOM"
op_text=
fm_operational_input_encode away-supervisor "Reply with exactly $OP_TOKEN and nothing else." op_text \
  || fail "could not encode an away-supervisor payload"
verdict=$(fm_backend_herdr_send_text_submit "$TARGET" "$op_text" 3 0.4 0.4) \
  || fail "send_text_submit failed to run an operational payload against Claude Code ($VERSION) on $HERDR_VER"
[ "$verdict" = empty ] \
  || fail "Claude Code ($VERSION) on $HERDR_VER: a landed U+2063 operational payload must confirm empty, got '$verdict'"
landed=0
i=0
while [ "$i" -lt 45 ]; do
  screen=$(lab pane read "$PANE" --source recent --lines 200 2>/dev/null || true)
  occurrences=$(printf '%s\n' "$screen" | grep -F -c "$OP_TOKEN" || true)
  if [ "$occurrences" -ge 2 ]; then
    landed=1
    break
  fi
  i=$((i + 1))
  sleep 1
done
[ "$landed" = 1 ] \
  || fail "Claude Code ($VERSION) on $HERDR_VER: operational submit reported '$verdict' but the expected reply never rendered"
pass "live Herdr submit confirm: Claude Code ($VERSION) on $HERDR_VER submits a U+2063 away-supervisor payload whose read-back drops the mark"

# The steering doorbell through the real fm-send, in this lab pane's default
# Herdr size (no client attached). The lab home's long directory name makes the
# doorbell wrap past the composer rows Claude shows, which every real worker
# doorbell did at 54x23: the read after typing then shows only its tail.
# shellcheck source=bin/fm-task-inbox-lib.sh
. "$ROOT/bin/fm-task-inbox-lib.sh"
wait_idle || fail "Claude Code ($VERSION) on $HERDR_VER never returned idle before the doorbell scenario"
DOORBELL_HOME=$("$ROOT/bin/fm-lab-home.sh" create "$TMP_ROOT/doorbell-home-padded-past-the-composer-rows") \
  || fail "could not create the doorbell lab home"
DOORBELL_ID='doorbell-live'
cat > "$DOORBELL_HOME/state/$DOORBELL_ID.meta" <<EOF
window=$TARGET
endpoint_task_id=$DOORBELL_ID
worktree=$ROOT
project=$ROOT
harness=claude
kind=ship
backend=herdr
herdr_session=$SESSION
herdr_workspace_id=$WS_ID
herdr_tab_id=$TAB_ID
herdr_pane_id=$PANE
EOF
doorbell=$(fm_task_inbox_doorbell_line "$DOORBELL_HOME/state/$DOORBELL_ID.inbox/001.msg") \
  || fail "could not render the steering doorbell"
# Assert the overflow itself, so this scenario cannot pass vacuously on a pane
# tall or wide enough to show the whole doorbell at once.
fm_backend_herdr_send_literal "$TARGET" "$doorbell" || fail "could not type the doorbell for the overflow check"
sleep 0.5
shown=$(fm_backend_herdr_composer_content "$TARGET") || shown=
fm_backend_herdr_composer_clear "$TARGET" "$doorbell" \
  || fail "Claude Code ($VERSION) on $HERDR_VER: could not clear the overflow-check doorbell"
if fm_backend_herdr_composer_payload_shown "$doorbell" "$shown"; then
  fail "Claude Code ($VERSION) on $HERDR_VER: the ${#doorbell}-character doorbell fit the composer view, so the scrolled-composer case was not exercised"
fi
DOORBELL_TOKEN="FMHERDRDOORBELL$$_$RANDOM"
DOORBELL_ACK="$TMP_ROOT/$DOORBELL_TOKEN.txt"
send_err=$(FM_HOME="$DOORBELL_HOME" "$ROOT/bin/fm-send.sh" "$DOORBELL_ID" \
  "Create the file $DOORBELL_ACK containing the single word $DOORBELL_TOKEN, then stop." 2>&1 >/dev/null) \
  || fail "fm-send could not record the doorbell steer: $send_err"
case "$send_err" in
  *'doorbell did not reach'*|*'doorbell skipped'*|*'doorbell not typed'*)
    fail "Claude Code ($VERSION) on $HERDR_VER: fm-send did not ring a ${#doorbell}-character doorbell into the idle worker: $(printf '%s\n' "$send_err" | grep -F 'fm-send: doorbell')"
    ;;
esac
acked=0
i=0
while [ "$i" -lt 120 ]; do
  if [ -f "$DOORBELL_HOME/state/$DOORBELL_ID.inbox/handled/001.msg" ] && [ -f "$DOORBELL_ACK" ]; then
    acked=1
    break
  fi
  i=$((i + 1))
  sleep 1
done
[ "$acked" = 1 ] \
  || fail "Claude Code ($VERSION) on $HERDR_VER: the rung doorbell was never acted on and acknowledged (record handled: $([ -f "$DOORBELL_HOME/state/$DOORBELL_ID.inbox/handled/001.msg" ] && echo yes || echo no), file created: $([ -f "$DOORBELL_ACK" ] && echo yes || echo no))"
grep -qF "$DOORBELL_TOKEN" "$DOORBELL_ACK" \
  || fail "Claude Code ($VERSION) on $HERDR_VER: the worker created $DOORBELL_ACK without the requested token"
pass "live Herdr submit confirm: Claude Code ($VERSION) on $HERDR_VER acts on and acknowledges a ${#doorbell}-character fm-send doorbell scrolled past its composer view"

# The fm-control exit regression: a typed slash command (/exit) makes Claude
# Code 2.1.283 render its command popup between the composer and the pane
# bottom, which pushed the composer above the old bounded proof read - the
# typed command was judged unsent, cleared, and never submitted. The viewport
# capture must prove the typed /exit and submit it; Claude must actually
# exit. This scenario runs last because it ends the lab's Claude process.
wait_idle || true
verdict=$(fm_backend_herdr_send_text_submit "$TARGET" '/exit' 3 0.4 1.2) \
  || fail "send_text_submit failed to run the /exit submission against Claude Code ($VERSION) on $HERDR_VER"
[ "$verdict" != send-failed ] \
  || fail "Claude Code ($VERSION) on $HERDR_VER: a typed /exit behind its command popup was judged unsent and cleared instead of submitted"
exited=0
i=0
while [ "$i" -lt 30 ]; do
  if ! lab agent get "$PANE" >/dev/null 2>&1; then exited=1; break; fi
  i=$((i + 1))
  sleep 1
done
[ "$exited" = 1 ] \
  || fail "Claude Code ($VERSION) on $HERDR_VER: the /exit submission reported '$verdict' but the agent never exited"
pass "live Herdr submit confirm: Claude Code ($VERSION) on $HERDR_VER proves and submits a typed /exit behind its command popup"

[ "$CHECKED" -gt 0 ] || fail "FM_HERDR_SUBMIT_CONFIRM_LIVE=1 checked no harness"
