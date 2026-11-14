#!/usr/bin/env bash
# Drives fm-bearings-snapshot.sh live against a disposable lab home.
# usage: drive.sh <repo-root-with-bin> <lab> [extra bearings args...]
set -u
ROOT=$1; LAB=$2; shift 2
TMUX_TMPDIR="$LAB/tmux" env -u TMUX -u NO_MISTAKES_GATE -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE \
  FM_HOME="$LAB" "$ROOT/bin/fm-bearings-snapshot.sh" "$@"
