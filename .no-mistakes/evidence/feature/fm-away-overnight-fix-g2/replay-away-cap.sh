#!/usr/bin/env bash
# Replay of the 2026-10-19 stall: away cap 4, 1 worker still working,
# 4 finished records (scout reports delivered, done) waiting on cleanup.
# Usage: replay-away-cap.sh <repo-root-whose-bin-to-use> <label> <scratch-dir>
set -u
BIN_ROOT=$1
LABEL=$2
T=$3
home=$T/home
root=$T/root
fb=$T/fakebin
mkdir -p "$home/state" "$home/data" "$home/config" "$root" "$fb"
git init -q -b main "$root"
git -C "$root" -c user.name=t -c user.email=t@t commit -q --allow-empty -m init
ln -s "$BIN_ROOT/bin" "$root/bin"
cat > "$fb/tmux" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  display-message) printf '%%1\n' ;;
  capture-pane) printf 'all quiet\n> \n' ;;
esac
exit 0
SH
chmod +x "$fb/tmux"

mark() { # mark <id> busy|idle
  local gen
  gen=$("$BIN_ROOT/bin/fm-busy-event.sh" arm "$home/state" "$1")
  if [ "$2" = busy ]; then
    "$BIN_ROOT/bin/fm-busy-event.sh" apply "$home/state" "$1" busy --gen "$gen" --source claude-hook --event user-prompt-submit
  else
    "$BIN_ROOT/bin/fm-busy-event.sh" apply "$home/state" "$1" idle --gen "$gen" --source claude-hook --event stop
  fi
}

for id in scout-a scout-b scout-c scout-d live-1; do
  mkdir -p "$home/wt/$id"
  printf 'window=fm:fm-%s\nworktree=%s\nkind=scout\nharness=claude\n' "$id" "$home/wt/$id" > "$home/state/$id.meta"
  if [ "$id" = live-1 ]; then
    mark "$id" busy
    printf 'working [at=1]: implementing\n' > "$home/state/$id.status"
  else
    mark "$id" idle
    printf 'done [at=1]: report written to data/%s/report.md\n' "$id" > "$home/state/$id.status"
  fi
done

echo "=== [$LABEL] away entered with --spend 4; records: 4 finished scouts + 1 working ==="
FM_HOME="$home" "$BIN_ROOT/bin/fm-afk-contract.sh" enter --spend 4 >/dev/null
for n in 1 2 3 4; do
  echo "\$ fm-spawn.sh queued-$n --mode no-mistakes --yolo off"
  out=$(PATH="$fb:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$root" \
    "$BIN_ROOT/bin/fm-spawn.sh" "queued-$n" --mode no-mistakes --yolo off 2>&1)
  st=$?
  if printf '%s' "$out" | grep -q "caps concurrent workers"; then
    echo "  REFUSED (exit $st): $(printf '%s' "$out" | grep "caps concurrent workers" | head -1)"
  else
    echo "  ADMITTED past the away spend cap (exit $st)"
    # Model the admitted spawn as a live working worker, like a launched agent.
    mkdir -p "$home/wt/queued-$n"
    printf 'window=fm:fm-queued-%s\nworktree=%s\nkind=scout\nharness=claude\n' "$n" "$home/wt/queued-$n" > "$home/state/queued-$n.meta"
    printf 'working [at=1]: implementing\n' > "$home/state/queued-$n.status"
    mark "queued-$n" busy
  fi
done
