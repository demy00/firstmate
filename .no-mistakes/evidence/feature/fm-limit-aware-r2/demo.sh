#!/usr/bin/env bash
# Demo: usage-limit stop declaration and resume, via the real bin/fm-claude-usage.sh.
# fm-send.sh is replaced by a stand-in that prints the steer instead of typing into tmux.
# Usage: demo.sh <worktree>
W=$1
D=$(mktemp -d)
mkdir -p "$D/bin" "$D/home/state"
for f in "$W"/bin/*; do [ "${f##*/}" = fm-send.sh ] || ln -s "$f" "$D/bin/"; done
printf '#!/usr/bin/env bash\necho "[fm-send stand-in] steer to $1: $2"\n' > "$D/bin/fm-send.sh"
chmod +x "$D/bin/fm-send.sh"
for id in fz-a fz-b fz-d; do touch "$D/home/state/$id.meta"; done
S=$(date -j -u -f '%Y-%m-%dT%H:%M:%S' 2026-09-09T08:00:00 +%s)
R=$(date -j -u -f '%Y-%m-%dT%H:%M:%S' 2026-09-09T09:41:00 +%s)
payload() { jq -cn --arg m "$1" '{hook_event_name:"StopFailure",error:"rate_limit",last_assistant_message:$m}'; }
U="$D/bin/fm-claude-usage.sh"

echo '# 2026-09-09 08:00Z: the account limit stops three workers; each StopFailure hook fires'
for id in fz-a fz-b; do payload "You've hit your session limit · resets 11:40am (Europe/Budapest)" | FM_CLAUDE_USAGE_NOW=$S "$U" stop-failure "$D/home/state" "$id"; done
payload "You've hit your weekly limit · resets Sep 12 at 7pm (Europe/Budapest)" | FM_CLAUDE_USAGE_NOW=$S "$U" stop-failure "$D/home/state" fz-d
for id in fz-a fz-b fz-d; do echo "\$ cat state/$id.status"; cat "$D/home/state/$id.status"; done
echo
echo '# 09:40Z: firstmate tries to resume fz-a before the reset'
echo '$ fm-claude-usage.sh resume fz-a'
FM_HOME="$D/home" FM_CLAUDE_USAGE_NOW=$((R - 60)) "$U" resume fz-a 2>&1; echo "exit=$?"
echo
echo '# 09:42Z: the session reset passed; one command recovers every freed worker'
echo '$ fm-claude-usage.sh resume --due'
FM_HOME="$D/home" FM_CLAUDE_USAGE_NOW=$((R + 60)) "$U" resume --due 2>&1; echo "exit=$?"
for id in fz-a fz-b fz-d; do echo "\$ cat state/$id.status"; cat "$D/home/state/$id.status"; done
