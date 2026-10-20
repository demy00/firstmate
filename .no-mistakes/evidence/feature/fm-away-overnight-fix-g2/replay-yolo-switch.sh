#!/usr/bin/env bash
# Replay of the 2026-10-19 posture miss: ada switched to +yolo in the evening
# while three ada ship tasks were already running with yolo=off recorded, and
# dependent ada steps were queued with "yolo off" in their notes.
# Usage: replay-yolo-switch.sh <repo-root> <scratch-home>
set -u
ROOT=$1
home=$2
mkdir -p "$home/state" "$home/data" "$home/projects/ada" "$home/projects/other"
{
  printf '# Projects\n\n'
  printf -- '- ada [no-mistakes +yolo] - Ada library (added 2026-10-01)\n'
  printf -- '- other [no-mistakes] - another library (added 2026-10-01)\n'
} > "$home/data/projects.md"
printf '## In flight\n\n## Queued\n\n## Done\n' > "$home/data/backlog.md"
for id in ada-1 ada-2 ada-3; do
  printf 'window=fm-%s\nproject=%s\nkind=ship\nmode=no-mistakes\nyolo=off\nbranch=feature/ada-g2\n' "$id" "$home/projects/ada" > "$home/state/$id.meta"
done
printf 'window=fm-other-1\nproject=%s\nkind=ship\nmode=no-mistakes\nyolo=off\n' "$home/projects/other" > "$home/state/other-1.meta"
tx() { FM_HOME="$home" "$ROOT/bin/fm-tasks-axi.sh" "$@" >/dev/null; }
tx add ada-4 "Ada step 4" --repo ada --kind ship --body "mode no-mistakes, yolo off; runs after ada-3."
tx add ada-5 "Ada step 5" --repo ada --kind ship --body "Runs after ada-4."
tx add other-q "Other step" --repo other --kind ship --body "mode no-mistakes, yolo off"

echo "=== before: recorded yolo of live ship tasks ==="
grep -H '^yolo=' "$home/state/"*.meta | sed "s|$home/state/||"
echo "=== before: data/backlog.md ==="
cat "$home/data/backlog.md"
echo
echo "\$ fm-project-yolo-apply.sh ada"
FM_HOME="$home" "$ROOT/bin/fm-project-yolo-apply.sh" ada 2>&1
echo "(exit $?)"
echo
echo "=== after: recorded yolo of live ship tasks ==="
grep -H '^yolo=' "$home/state/"*.meta | sed "s|$home/state/||"
echo "=== after: data/backlog.md ==="
cat "$home/data/backlog.md"
