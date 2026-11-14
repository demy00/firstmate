#!/usr/bin/env bash
# Seeds a lab home mirroring report section 3.1: 23 open captain holds
# (10 live, 9 aged undated, 2 dated, 2 blocked) plus 25 newer ordinary queued
# tasks, and a secondmate home with 25 newer queued rows + 2 old aged holds.
set -u
LAB=$1; MATE=$2
{
printf '## In flight\n\n## Queued\n'
for i in $(seq -w 1 10); do  # live holds: filed recently (< 14 days)
  printf -- '- [ ] live-%s - Live call %s (repo: sample) (kind: captain) (since 2026-11-%s) (hold: pick A or B) (hold-kind: captain)\n  Captain hold set: 2026-11-%sT00:00:00Z\n' $i $i $i $i
done
for i in $(seq -w 1 9); do   # aged: filed 2026-0[1-9]-15
  printf -- '- [ ] aged-%s - Aged call filed 2026-0%s (repo: sample) (kind: captain) (since 2026-0%s-15) (hold: choose a route) (hold-kind: captain)\n  Captain hold set: 2026-0%s-15T00:00:00Z\n' $i ${i#0} ${i#0} ${i#0}
done
printf -- '- [ ] dated-a - Dated call (repo: sample) (kind: captain) (since 2026-03-02) (hold: parked) (hold-kind: captain) (hold-until: 2027-01-01)\n'
printf -- '- [ ] dated-b - Dated call b (repo: sample) (kind: captain) (since 2026-07-02) (hold: parked) (hold-kind: captain) (hold-until: 2027-02-01)\n'
printf -- '- [ ] blocked-a - Blocked call blocked-by: never-done (repo: sample) (kind: captain) (since 2026-02-20) (hold: parked) (hold-kind: captain)\n'
printf -- '- [ ] blocked-b - Blocked call b blocked-by: never-done (repo: sample) (kind: captain) (since 2026-10-20) (hold: parked) (hold-kind: captain)\n'
for i in $(seq -w 1 25); do
  printf -- '- [ ] work-%s - Newer queued work %s (repo: sample) (kind: ship) (since 2026-10-%s)\n' $i $i $i
done
printf -- '- [ ] never-done - Blocker work (repo: sample) (kind: ship) (since 2026-01-01)\n'
printf '\n## Done\n'
} > "$LAB/data/backlog.md"
mkdir -p "$MATE/state" "$MATE/data" "$MATE/config" "$MATE/projects" "$MATE/bin"
printf '# Firstmate lab mate\n' > "$MATE/AGENTS.md"
printf 'lab-mate\n' > "$MATE/.fm-secondmate-home"
{
printf '## In flight\n\n## Queued\n'
for i in $(seq -w 1 25); do
  printf -- '- [ ] mate-work-%s - Mate work %s (repo: sample) (kind: ship) (since 2026-10-%s)\n' $i $i $i
done
printf -- '- [ ] mate-aged-old - Mate oldest call (repo: sample) (kind: captain) (since 2026-01-10) (hold: remote route) (hold-kind: captain)\n  Captain hold set: 2026-01-10T00:00:00Z\n'
printf -- '- [ ] mate-aged-new - Mate newer aged call (repo: sample) (kind: captain) (since 2026-08-10) (hold: remote route 2) (hold-kind: captain)\n  Captain hold set: 2026-08-10T00:00:00Z\n'
printf '\n## Done\n'
} > "$MATE/data/backlog.md"
printf -- '- lab-mate - lab domain (home: %s; scope: lab; projects: sample; added 2026-11-01)\n' "$MATE" > "$LAB/data/secondmates.md"
