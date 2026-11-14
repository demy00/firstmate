#!/usr/bin/env bash
set -u
EV=~/.no-mistakes/evidence/01M7E34D8RYYJ29DB1FVPN69AG; LOG=$EV/live-watcher-transcript.log; : > "$LOG"
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX"); bin/fm-lab-home.sh create "$LAB" >/dev/null
printf 'backend = "markdown"\n\n[markdown]\npath = "data/backlog.md"\narchive = "data/done-archive.md"\ndone_keep = 10\n' > "$LAB/.tasks.toml"
printf '## In flight\n\n## Queued\n\n## Done\n' > "$LAB/data/backlog.md"; touch "$LAB/state/home-summary.json"
E(){ env -u NO_MISTAKES_GATE -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE FM_HOME="$LAB" "$@"; }
run(){ echo "\$ $*" >>"$LOG"; E "$@" >>"$LOG" 2>&1; echo "[exit $?]" >>"$LOG"; }
watch(){ echo "\$ bin/fm-watch.sh   (alarm ${1}s => exit 142 means it stayed asleep)" >>"$LOG"; rm -f "$LAB/state/.last-check"; E perl -e 'alarm(shift); exec(@ARGV)' "$1" bin/fm-watch.sh >>"$LOG" 2>&1; echo "[exit $?]" >>"$LOG"; }
drain_ack(){ local out ack; echo "\$ bin/fm-wake-drain.sh" >>"$LOG"; out=$(E bin/fm-wake-drain.sh 2>&1); echo "$out" >>"$LOG"
  ack=$(printf '%s\n' "$out" | sed -n 's/.*run bin\/fm-wake-drain.sh \(--ack-through .*\)$/\1/p' | tail -1)
  [ -z "$ack" ] || { echo "\$ bin/fm-wake-drain.sh $ack" >>"$LOG"; E bin/fm-wake-drain.sh $ack >>"$LOG" 2>&1; echo "[exit $?]" >>"$LOG"; }; }
TODAY=$(date -u +%F)
echo "# disposable lab home (bin/fm-lab-home.sh create); today(UTC)=$TODAY" >>"$LOG"
echo "## S1 setup: holds due today, overdue, future, undated" >>"$LOG"
run bin/fm-captain-hold.sh hold due-q --reason "pick a DB" --title "Pick DB" --repo x --until "$TODAY"
run bin/fm-captain-hold.sh hold past-q --reason "pick a name" --title "Pick name" --repo x --until 2026-11-01
run bin/fm-captain-hold.sh hold future-q --reason "later" --title "Later" --repo x --until 2026-12-31
run bin/fm-captain-hold.sh hold undated-q --reason "open q" --title "Open" --repo x
run bin/fm-captain-hold.sh due
echo "## S1 watcher run 1: expect one wake naming due-q and past-q only" >>"$LOG"
watch 30
echo "--- ledger STATE/.captain-hold-due ---" >>"$LOG"; cat "$LAB/state/.captain-hold-due" >>"$LOG"; echo >>"$LOG"
drain_ack
echo "## S2 watcher run 2, same holds and dates: expect NO captain-hold wake (watcher sleeps until alarm)" >>"$LOG"
watch 20
echo "--- captain-hold rows ever queued: ---" >>"$LOG"; grep -c 'captain-hold-due' "$LAB/state/.wake-queue" >>"$LOG" 2>&1 || echo "0 (queue drained)" >>"$LOG"
drain_ack
echo "## S3 re-hold past-q with a new date 2026-11-05 (already arrived): expect one new wake for that date" >>"$LOG"
run bin/fm-captain-hold.sh hold past-q --reason "pick a name" --title "Pick name" --repo x --until 2026-11-05
watch 30
drain_ack
echo "## S4 answer due-q and release none; due list and watcher stay silent for it" >>"$LOG"
echo "use postgres" > "$LAB/dec"; run bin/fm-captain-hold.sh answer due-q --decision-file "$LAB/dec"
run bin/fm-captain-hold.sh due
watch 20
drain_ack
echo "## S5 adversarial: malformed --today refused" >>"$LOG"
run bin/fm-captain-hold.sh due --today 2026/11/14
echo "## S6 adversarial: unreadable backlog -> due exits 2, watcher wakes nothing, ledger untouched" >>"$LOG"
cp "$LAB/state/.captain-hold-due" "$LAB/ledger.before"
run bin/fm-captain-hold.sh hold late-q --reason "late" --title "Late" --repo x --until 2026-11-02
cp "$LAB/.tasks.toml" "$LAB/toml.good"; printf 'backend = "nonesuch"\n' > "$LAB/.tasks.toml"
run bin/fm-captain-hold.sh due
watch 20
cmp -s "$LAB/ledger.before" "$LAB/state/.captain-hold-due" && echo "ledger unchanged: yes" >>"$LOG" || echo "ledger unchanged: NO" >>"$LOG"
grep 'due-date' "$LAB/state/"*triage* >>"$LOG" 2>/dev/null
drain_ack
cp "$LAB/toml.good" "$LAB/.tasks.toml"
echo "## S6b backlog readable again: late-q wakes once" >>"$LOG"
watch 30
drain_ack
rm -rf "$LAB"; [ -e "$LAB" ] && echo "# lab NOT removed" >>"$LOG" || echo "# lab removed" >>"$LOG"
