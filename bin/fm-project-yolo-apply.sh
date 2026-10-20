#!/usr/bin/env bash
# Apply a project's REGISTERED yolo posture to this home's live ship tasks of
# that project and to its queued ship backlog items. A ship task records its
# yolo= merge authority in state/<id>.meta at spawn or promotion, and every
# merge decision reads that record, so a captain change to the project's +yolo
# token in data/projects.md reaches no task that is already running until this
# command rewrites it. A queued ship item carries the posture firstmate
# recorded in its backlog note at intake and passes to the later spawn, so its
# note is rewritten too; in-flight and done items are never touched.
# Firstmate runs it right after making that registry change, in either
# direction: switching +yolo on hands the project's running ships routine
# merge authority, and switching it off takes that authority back.
#
# The posture comes only from bin/fm-project-mode.sh, which owns the registry:
# a forge=gerrit project always reports yolo=off, an unregistered project
# resolves to off with its warning passed through, and a registry entry that
# does not resolve (its refusal is passed through) changes no task at all.
# Only yolo= changes. Delivery mode, branch, and every other field keep their
# recorded values, and scouts and secondmates, which carry no merge posture,
# are never touched. Merge authority stays exactly what yolo always meant:
# bin/fm-pr-merge.sh's green-head, red-check, and away-record gates, and the
# escalation of destructive, irreversible, and security-sensitive merges, are
# unchanged by this record.
#
# A queued item's note is read and written only through bin/fm-tasks-axi.sh.
# Only its posture tokens change - `yolo on`, `yolo off` (also spelled with
# `=` or `:`), and `+yolo` - and every other byte of the note is kept; a note
# that records no posture gains one closing sentence naming the registry
# posture. A backlog read or write failure leaves the run incomplete.
#
# Each task is rewritten under its lifecycle lock (state/.control-<id>.lock,
# tried once so a running relaunch or promotion is never raced) and its meta
# lock, then published atomically. A task whose lifecycle lock is busy is
# skipped and named; the command then exits 1 and is safe to rerun, because a
# task already carrying the posture is reported unchanged.
#
# Usage: fm-project-yolo-apply.sh <project> [<task-id>...]
#   <project> is the registry name, matched against the basename of each
#   task's recorded project= path and against each queued item's repo.
#   Named task ids limit the apply to those tasks; each must be a live ship
#   task or a queued ship item of <project>, or nothing is changed.
#   Prints one line per task ("<id>: yolo <old> -> <new>" or
#   "<id>: yolo <value> (unchanged)"), one per queued item
#   ("<id>: queued note yolo <old> -> <new>" or
#   "<id>: queued note yolo <value> (unchanged)"), and a closing summary.
#   Exit 0 when every task and queued item carries the posture, 1 when one was
#   skipped or could not be rewritten, the backlog could not be read, or the
#   registry posture does not resolve, and 2 on a usage error.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

usage() {
  sed -n '/^# Usage:/,/^set -eu/p' "${BASH_SOURCE[0]}" | sed '$d' | sed 's/^# \{0,1\}//'
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
  ''|-*) echo "usage: fm-project-yolo-apply.sh <project> [<task-id>...]" >&2; exit 2 ;;
esac
PROJECT=$1
shift

# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-tasks-axi-lib.sh
. "$SCRIPT_DIR/fm-tasks-axi-lib.sh"
# shellcheck source=bin/fm-backlog-transition-lib.sh
. "$SCRIPT_DIR/fm-backlog-transition-lib.sh"

[ -d "$STATE" ] || { echo "error: state dir not found: $STATE" >&2; exit 1; }

if ! POSTURE=$(FM_HOME="$FM_HOME" "$SCRIPT_DIR/fm-project-mode.sh" "$PROJECT"); then
  echo "error: the registry posture for $PROJECT does not resolve (see the refusal above); no task was changed" >&2
  exit 1
fi
YOLO=${POSTURE##* }
case "$YOLO" in
  on|off) ;;
  *) echo "error: the registry posture for $PROJECT is unreadable ('$POSTURE'); no task was changed" >&2; exit 1 ;;
esac

meta_value() {  # <meta> <key>
  grep "^$2=" "$1" 2>/dev/null | tail -1 | cut -d= -f2- || true
}

# 0 when <meta> is a regular task record of a ship task of PROJECT.
project_ship_meta() {  # <meta>
  local project kind
  [ -f "$1" ] && [ ! -L "$1" ] || return 1
  kind=$(meta_value "$1" kind)
  [ "$kind" = ship ] || return 1
  project=$(meta_value "$1" project)
  [ -n "$project" ] && [ "${project##*/}" = "$PROJECT" ]
}

tasks_axi() {
  FM_HOME="$FM_HOME" "$SCRIPT_DIR/fm-tasks-axi.sh" "$@" </dev/null 2>/dev/null
}

# The ids of PROJECT's queued ship backlog items, one per line; 1 when the
# backlog cannot be read.
queued_project_ships() {
  local out
  out=$(tasks_axi list --state queued --repo "$PROJECT" --kind ship) || return 1
  case "$out" in "count: "*) ;; *) return 1 ;; esac
  printf '%s\n' "$out" | sed -n 's/^  \([^ ,][^,]*\),queued,.*/\1/p'
}

line_listed() {  # <lines> <value>
  printf '%s\n' "$1" | grep -Fqx -- "$2"
}

TASKS=()
QUEUED=()
QUEUED_LISTED=0
BACKLOG_UNREAD=0
QUEUED_IDS=
if [ "$#" -gt 0 ]; then
  for id in "$@"; do
    if fm_pr_task_id_valid "$id" && project_ship_meta "$STATE/$id.meta"; then
      TASKS+=("$id")
      continue
    fi
    if [ "$QUEUED_LISTED" = 0 ]; then
      QUEUED_LISTED=1
      if ! QUEUED_IDS=$(queued_project_ships); then
        echo "error: the backlog could not be read to find $id; no task was changed" >&2
        exit 1
      fi
    fi
    if [ -n "$id" ] && line_listed "$QUEUED_IDS" "$id"; then
      QUEUED+=("$id")
      continue
    fi
    echo "error: $id is not a live ship task or a queued ship item of $PROJECT in this home; no task was changed" >&2
    exit 1
  done
else
  for meta in "$STATE"/*.meta; do
    project_ship_meta "$meta" || continue
    id=${meta##*/}
    TASKS+=("${id%.meta}")
  done
  if QUEUED_IDS=$(queued_project_ships); then
    while IFS= read -r id; do
      [ -z "$id" ] || QUEUED+=("$id")
    done <<EOF
$QUEUED_IDS
EOF
  else
    BACKLOG_UNREAD=1
  fi
fi

CONTROL_LOCK=
CONTROL_LOCK_HELD=0
META_LOCK=
META_LOCK_HELD=0
TMP=
release_task_locks() {
  [ -z "$TMP" ] || rm -f -- "$TMP" 2>/dev/null || true
  TMP=
  if [ "$META_LOCK_HELD" = 1 ]; then
    META_LOCK_HELD=0
    fm_lock_release "$META_LOCK" || true
  fi
  if [ "$CONTROL_LOCK_HELD" = 1 ]; then
    CONTROL_LOCK_HELD=0
    fm_lock_release "$CONTROL_LOCK" || true
  fi
}
trap release_task_locks EXIT

# Rewrite one task's yolo= under its locks; prints the task's line. Returns 1
# when the task was skipped or could not be rewritten.
apply_task() {  # <task-id>
  local id=$1 meta=$STATE/$1.meta old
  CONTROL_LOCK="$STATE/.control-$id.lock"
  if ! fm_lock_try_acquire "$CONTROL_LOCK"; then
    echo "$id: skipped - another lifecycle action is running for it; rerun this command"
    return 1
  fi
  CONTROL_LOCK_HELD=1
  META_LOCK=$(fm_meta_lock_path "$meta") || { echo "$id: skipped - its metadata lock path is invalid"; return 1; }
  fm_lock_acquire_wait "$META_LOCK"
  META_LOCK_HELD=1
  if ! fm_backlog_record_present "$meta" "task record" "$STATE" || ! project_ship_meta "$meta"; then
    echo "$id: skipped - its task record is gone or no longer a ship task of $PROJECT"
    return 1
  fi
  old=$(meta_value "$meta" yolo)
  if [ "$old" = "$YOLO" ]; then
    echo "$id: yolo $YOLO (unchanged)"
    return 0
  fi
  TMP="$STATE/.$id.meta.yolo-apply.${BASHPID:-$$}"
  { grep -v '^yolo=' "$meta" || true; echo "yolo=$YOLO"; } > "$TMP"
  if ! fm_backlog_atomic_transition publish "$TMP" "$meta" "task record" "$STATE"; then
    echo "$id: skipped - its task record could not be published ($FM_BACKLOG_TRANSITION_ERROR)"
    return 1
  fi
  TMP=
  echo "$id: yolo ${old:-unset} -> $YOLO"
}

# Rewrite the posture tokens of the note on stdin for posture $1, printing
# the new note; a note with no token gains a closing sentence.
rewrite_note_posture() {  # <on|off>
  perl -e '
    my $new = shift;
    local $/;
    my $note = <STDIN>;
    $note = "" unless defined $note;
    my $tokens = ($note =~ s/\b(yolo(?:[ \t]*[=:][ \t]*|[ \t]+))(?:on|off)\b/$1$new/gi);
    my $plus = qr/(?<![\w+-])\+yolo\b(?![=\w-])/;
    if ($new eq "off") {
      $tokens += ($note =~ s/$plus/yolo off/g);
    } else {
      $tokens += () = $note =~ /$plus/g;
    }
    if (!$tokens) {
      $note =~ s/\s+\z//;
      $note .= ($note eq "" ? "" : "\n") . "Delivery posture: yolo $new (project registry).";
    }
    print $note;
  ' "$1"
}

# The posture the note on stdin records, or "unrecorded".
note_posture() {
  perl -e '
    local $/;
    my $note = <STDIN>;
    $note = "" unless defined $note;
    if ($note =~ /\byolo(?:[ \t]*[=:][ \t]*|[ \t]+)(on|off)\b/i) { print lc $1 }
    elsif ($note =~ /(?<![\w+-])\+yolo\b(?![=\w-])/) { print "on" }
    else { print "unrecorded" }
  '
}

# Rewrite one queued item's note through the backlog; prints the item's line.
# Returns 1 when the note could not be read or written.
apply_queued() {  # <item-id>
  local id=$1 show field note new old
  if ! show=$(tasks_axi show "$id" --full) ||
    [ "$(printf '%s\n' "$show" | sed -n 's/^  state: //p' | head -1)" != queued ]; then
    echo "$id: skipped - its queued backlog item could not be read; rerun this command"
    return 1
  fi
  field=$(printf '%s\n' "$show" | sed -n 's/^  body: //p' | head -1)
  case "$field" in
    \"*\")
      if ! note=$(printf '%s' "$field" | perl -MJSON::PP -e '
        local $/;
        my $value = JSON::PP->new->utf8->allow_nonref->decode(<STDIN>);
        binmode STDOUT, ":raw";
        utf8::encode($value) if utf8::is_utf8($value);
        print $value;
      '); then
        echo "$id: skipped - its queued note could not be decoded"
        return 1
      fi
      ;;
    -) note= ;;
    *) note=$field ;;
  esac
  old=$(printf '%s' "$note" | note_posture)
  new=$(printf '%s' "$note" | rewrite_note_posture "$YOLO")
  if [ "$new" = "$note" ]; then
    echo "$id: queued note yolo $YOLO (unchanged)"
    return 0
  fi
  TMP=$(mktemp "${TMPDIR:-/tmp}/fm-yolo-apply-note.XXXXXX") || {
    echo "$id: skipped - no temporary file for its new note"
    return 1
  }
  printf '%s' "$new" > "$TMP"
  if ! tasks_axi update "$id" --body-file "$TMP" >/dev/null; then
    echo "$id: skipped - its queued note could not be written; rerun this command"
    return 1
  fi
  echo "$id: queued note yolo $old -> $YOLO"
}

RC=0
for id in ${TASKS[@]+"${TASKS[@]}"}; do
  apply_task "$id" || RC=1
  release_task_locks
done
if [ "$BACKLOG_UNREAD" = 1 ]; then
  echo "backlog: skipped - the queued ship items of $PROJECT could not be read; rerun this command"
  RC=1
fi
for id in ${QUEUED[@]+"${QUEUED[@]}"}; do
  apply_queued "$id" || RC=1
  release_task_locks
done
if [ "$RC" -eq 0 ]; then
  echo "applied: $PROJECT yolo=$YOLO to ${#TASKS[@]} live ship task(s) and ${#QUEUED[@]} queued ship item(s) in this home"
else
  echo "incomplete: $PROJECT yolo=$YOLO was not applied to every live ship task and queued ship item; rerun after the skipped ones' lifecycle actions finish" >&2
fi
exit "$RC"
