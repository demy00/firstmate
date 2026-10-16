#!/usr/bin/env bash
# fm-skill-usage.sh - print the weekly skill-usage table: which skills worker
# tasks loaded, split by repo, from the workers' own Claude transcripts.
#
# Usage:
#   fm-skill-usage.sh [--week YYYY-Www | --since YYYY-MM-DD --until YYYY-MM-DD] [--claude-root <dir>]
#
#   (no range)   the previous ISO week, Monday to Sunday, for the Monday
#                weekly report: run `bin/fm-skill-usage.sh` and paste its
#                output into data/reports/weekly/YYYY-Www.md.
#   --week       one ISO week, Monday to Sunday.
#   --since/--until  an inclusive range of local dates.
#   --claude-root    the Claude config root whose projects/ and skills/ are
#                read; default the root workers launch under: the pinned
#                config/claude-account root (bin/fm-worker-account-lib.sh),
#                else CLAUDE_CONFIG_DIR, else ~/.claude.
#
# Read-only: it reads transcripts and skill directories and writes only the
#   table to stdout. Exit 2 on a usage or configuration error.
#
# Tasks: every top-level <root>/projects/*treehouse*/*.jsonl transcript whose
#   messages carry a Firstmate launch brief is one worker task, identified by
#   the steering inbox the brief's own inbox line names (else the first inbox
#   it mentions), so a relaunched task's transcripts merge. A task belongs to
#   the range when its first message falls on a local date inside it. Its
#   repo is the treehouse worktree directory the session ran in. A brief
#   carrying a "Delivery contract: mode=" line is a ship; any other is a
#   scout.
#
# Loaded skills: a Skill tool call, a "Base directory for this skill:" skill
#   load (a slash invocation), a Read of a */SKILL.md file, or a Bash
#   cat/head/tail/sed/less/more/bat of one. A plugin prefix is dropped
#   (anthropic-skills:docx counts as docx).
#
# Output (Markdown): a summary line with the task count per repo and how many
#   briefs had a `# Required skills` section (bin/fm-skill-select.sh); one
#   table row per skill with the tasks that loaded it, the tasks whose brief
#   named it, and the loading tasks per repo; the named skills a task did not
#   load; the tasks that loaded no skill beyond the baseline no-mistakes and
#   captain-hold-lifecycle, by repo, with scouts marked; and the installed
#   <root>/skills a task never loaded.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-$FM_ROOT}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"

# shellcheck source=bin/fm-worker-account-lib.sh
. "$SCRIPT_DIR/fm-worker-account-lib.sh"

die() { printf 'error: %s\n' "$1" >&2; exit 2; }
usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}

command -v python3 >/dev/null 2>&1 || die "python3 required"
for arg in "$@"; do
  case "$arg" in
    -h|--help) usage; exit 0 ;;
    --claude-root|--claude-root=*) exec python3 "$SCRIPT_DIR/fm-skill-usage.py" "$@" ;;
  esac
done

selection=$(fm_worker_account_resolve claude "$CONFIG") || die "config/claude-account does not resolve"
if [ -n "$selection" ]; then
  root=${selection#*$'\t'}
  root=${root%%$'\t'*}
  root=${root:-$HOME/.claude}
else
  root=${CLAUDE_CONFIG_DIR:-$HOME/.claude}
fi
exec python3 "$SCRIPT_DIR/fm-skill-usage.py" --claude-root "$root" "$@"
