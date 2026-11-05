#!/usr/bin/env bash
# fm-away-spend-lib.sh - the one reading of whether a worker has stopped spending,
# shared by the away spend cap's entry default (bin/fm-afk-contract.sh) and its
# refusal (bin/fm-spawn.sh), so finished work can neither raise the cap nor hold a
# slot under it.
#
# Sourceable only. The caller loads bin/fm-timeout-lib.sh, bin/fm-busy-lib.sh,
# bin/fm-backend.sh, and bin/fm-classify-lib.sh first.

# 0 when <task>'s current state shows a worker that has stopped spending.
# bin/fm-crew-state.sh owns that reading (its forge fallback is skipped
# because it only refines the detail of a terminal reading), and only these
# readings free a slot:
#   - done;
#   - failed, from the status log (reached only on an idle pane) or from a
#     run step while the busy contract (bin/fm-busy-lib.sh) reads the pane
#     idle, so a worker still fixing its failed run keeps counting;
#   - parked on a decision a human owes: a needs-decision from the status
#     log, or a run-step gate carrying the whole FM_GATE_HUMAN_DECISION
#     component (bin/fm-classify-lib.sh), so a gate the worker answers itself
#     keeps counting;
#   - an endpoint the backend's recovery-grade classifier proved gone or
#     agentless (tmux and herdr), never a probe that failed to answer.
# Every other state - working, any other gate, a declared wait on its own
# validation, a blocker firstmate still has to clear, a torn-down worktree,
# unknown, or a read that hit its bound - keeps the task counted.
fm_away_task_stopped_spending() {  # <task-id> <state-dir> <data-dir> <projects-dir> <config-dir>
  local task=$1 state_dir=$2 data_dir=$3 projects_dir=$4 config_dir=$5
  local line state src rest part busy
  line=$(fm_run_timed "${FM_SPAWN_CREW_STATE_TIMEOUT:-15}" \
    env FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$state_dir" FM_DATA_OVERRIDE="$data_dir" \
    FM_PROJECTS_OVERRIDE="$projects_dir" FM_CONFIG_OVERRIDE="$config_dir" FM_CREW_STATE_NO_FORGE=1 \
    "$(dirname "${BASH_SOURCE[0]}")/fm-crew-state.sh" "$task" </dev/null 2>/dev/null | head -1) || true
  case "$line" in "state: "*" · source: "*) ;; *) return 1 ;; esac
  state=${line#state: }
  state=${state%% *}
  src=${line#* · source: }
  src=${src%% *}
  case "$state:$src" in
  done:*) return 0 ;;
  failed:status-log) return 0 ;;
  failed:run-step)
    busy=$(fm_busy_classify_meta "$state_dir/$task.meta" "$task" "$state_dir" 2>/dev/null) || return 1
    [ "${busy%% *}" = idle ]
    return
    ;;
  parked:status-log) return 0 ;;
  parked:run-step)
    rest="$line · "
    while [ -n "$rest" ]; do
      part=${rest%% · *}
      rest=${rest#* · }
      [ "$part" != "$FM_GATE_HUMAN_DECISION" ] || return 0
    done
    return 1
    ;;
  unknown:none)
    case "$line" in *" · backend target gone: "*) ;; *) return 1 ;; esac
    case "$(fm_backend_of_meta "$state_dir/$task.meta")" in
    tmux | herdr) return 0 ;;
    esac
    return 1
    ;;
  esac
  return 1
}
