#!/usr/bin/env bash
# Manual demo: fm-spawn against legacy briefs (no "Ship branch:" line) from both eras.
set -u
R=$1; D=$2
home=$D/home; proj=$D/proj; fb=$D/bin
mkdir -p "$home/data" "$home/state" "$home/config" "$proj" "$fb"; git -C "$proj" init -q
printf '#!/bin/sh\nexit 1\n' > "$fb/tmux"; chmod +x "$fb/tmux"
echo "- proj [no-mistakes] - fixture (added 2026-01-01)" > "$home/data/projects.md"
mk() {
  mkdir -p "$home/data/$1"
  printf 'You are a crewmate.\n\n# Task\n## Captain'\''s intent\nX.\n\n## Firstmate spec\nY.\n\n# Definition of done\nDelivery contract: mode=no-mistakes\n1. First action: create your branch: `git checkout -b %s`\n' "$2" > "$home/data/$1/brief.md"
}
spawn() {
  FM_ROOT_OVERRIDE='' FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$D/none" FM_CONFIG_OVERRIDE="$home/config" FM_SPAWN_NO_GUARD=1 FM_BACKEND=tmux \
    PATH="$fb:$PATH" "$R/bin/fm-spawn.sh" "$@" --mode no-mistakes --yolo off 2>&1
}
echo '### Default branch name for a new task (fork change #3)'
( source "$R/bin/fm-task-branch-lib.sh"
  echo "fm_task_branch demo-1            -> $(fm_task_branch demo-1)"
  echo "fm_task_branch_candidates demo-1 -> $(fm_task_branch_candidates demo-1 | tr '\n' ' ')" )
echo; echo '### 1. Upstream-era legacy brief renders `git checkout -b fm/legacy-up`, spawned with default feature/ prefix'
mk legacy-up fm/legacy-up; spawn legacy-up "$proj" claude
echo "exit=$?  meta_written=$([ -e "$home/state/legacy-up.meta" ] && echo yes || echo no)"
echo; echo '### 2. Fork-era legacy brief renders `git checkout -b feature/legacy-fork`, spawned with default prefix'
mk legacy-fork feature/legacy-fork; spawn legacy-fork "$proj" claude
echo "exit=$? (fake tmux refuses only after all branch checks pass)"
echo; echo '### 3. Upstream-era brief spawned with matching --branch-prefix fm/'
mk legacy-up2 fm/legacy-up2; spawn legacy-up2 "$proj" claude --branch-prefix fm/
echo "exit=$?"
