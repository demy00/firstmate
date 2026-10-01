#!/usr/bin/env bash
# fm-skill-select.sh - choose which installed skills a crewmate or scout must
# load for its task, with typesafe.ai's System One model (Jev), opt-in, and
# write the choice into the brief as an explicit instruction.
#
# Usage:
#   fm-skill-select.sh <brief-file> --project <name> --harness <h> [--project-dir <dir>] [--apply]
#   fm-skill-select.sh <brief-file> --project <name> --harness <h> [--project-dir <dir>] --set <skill>[,<skill>...]
#   fm-skill-select.sh <brief-file> --clear
#   fm-skill-select.sh --candidates --project <name> --harness <h> [--project-dir <dir>]
#
#   (default)    ask Jev and print the selection; the brief is not touched.
#   --apply      ask Jev and, on status clear only, write the selection into
#                the brief's `# Required skills` section.
#   --set        write exactly these candidate skills instead (firstmate's
#                override); no key and no network. Repeatable.
#   --clear      remove the `# Required skills` section; no key and no network.
#   --candidates list the skills available to the worker; no key and no network.
#
# Candidates: the skills the selected harness discovers for a worker in a task
#   worktree of the project - its project-level skill directories, read from
#   the project's local clone ($FM_HOME/projects/<name>, or --project-dir), and
#   its user-level skill directories. Each candidate is one <dir>/<skill>/SKILL.md
#   whose frontmatter has a description and does not set
#   `disable-model-invocation: true` (a skill the worker model cannot invoke).
#   The frontmatter `name` (else the directory name) identifies it; the first
#   directory in the harness's order wins a duplicate name. Only the name and
#   description are ever sent, never a skill body.
#   Directories per harness (project paths are relative to the clone):
#     claude    <user root>/skills, .claude/skills; the user root is the pinned
#               config/claude-account root (bin/fm-worker-account-lib.sh), else
#               CLAUDE_CONFIG_DIR, else ~/.claude
#     codex     .agents/skills, .codex/skills, ${CODEX_HOME:-~/.codex}/skills, ~/.agents/skills
#     opencode  .opencode/skills, .opencode/skill, .claude/skills, .agents/skills,
#               ~/.config/opencode/skills, ~/.config/opencode/skill, ~/.claude/skills, ~/.agents/skills
#     gemini    .gemini/skills, .agents/skills, ~/.gemini/skills, ~/.agents/skills
#     devin     .agents/skills, ~/.agents/skills
#   Any other harness has no established skill directories: the off outcome.
#
# Opt-in gate and never-send list: exactly bin/fm-dispatch-resolve.sh's
#   (bin/fm-typesafe-lib.sh owns both). Off - no key, a never-send match, or
#   no candidates - prints one "skill-select: off (...)" line on stderr,
#   nothing on stdout, changes nothing, makes no network call, and exits 0.
#
# What it sends when on: one POST with the project name and the brief's task
#   text (the same sections the dispatch resolver sends) as state, and one
#   yes/no question per candidate whose text is that skill's name and
#   description. docs/verification/skill-select.md records why one yes/no
#   question per skill was chosen over one Choice question.
#   Code then applies the confidence floor: a skill is selected only when its
#   yes probability is at least 0.8. Jev never sees the floor.
#
# Output (stdout, TOON-style block):
#   skill-select:
#     status: clear | none | error
#     model/latency_ms/tokens
#     skill: <name> p=<yes probability> -> selected | below floor   (one per candidate, most probable first)
#     reason: <why the status is not clear>
#     skills: <name>...                                             (status clear only)
#     brief: written | unchanged
#   clear -> at least one skill cleared the floor
#   none  -> no skill cleared the floor; dispatch as today
#   error -> API, network, or response failure; dispatch as today
#   Every outcome exits 0 so an intake is never blocked by this tool; exit 2
#   only for a usage or configuration error, which is actionable.
#
# The `# Required skills` section: this script is the single owner of its text
#   and position. It sits directly after the brief's `# Task` section, so it is
#   outside the task text every classifier and the no-mistakes --intent read,
#   and it is rewritten in place, never duplicated. A brief without a `# Task`
#   heading is refused. The section names each skill with the path of its
#   SKILL.md (relative to the worktree for project skills) so a worker on any
#   harness can load it.
#
# Authority: this tool never replaces firstmate's judgment; firstmate reads the
#   selection before spawn and may --set or --clear it.
set -u

TYPESAFE_API_KEY_PRIVATE=${TYPESAFE_API_KEY:-}
export -n TYPESAFE_API_KEY_PRIVATE 2>/dev/null || true
unset TYPESAFE_API_KEY

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-$FM_ROOT}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"

# shellcheck source=bin/fm-typesafe-lib.sh
. "$SCRIPT_DIR/fm-typesafe-lib.sh"
# shellcheck source=bin/fm-worker-account-lib.sh
. "$SCRIPT_DIR/fm-worker-account-lib.sh"

YES_FLOOR=0.8
SECTION_HEADING='# Required skills'

die() { printf 'error: %s\n' "$1" >&2; exit 2; }
off() { echo "skill-select: off ($1)" >&2; exit 0; }
usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}

BRIEF='' PROJECT='' PROJECT_DIR='' HARNESS='' MODE=select SET_LIST=''
while [ $# -gt 0 ]; do
  case "$1" in
    --project) [ $# -ge 2 ] || die "--project needs a value"; PROJECT=$2; shift 2 ;;
    --project-dir) [ $# -ge 2 ] || die "--project-dir needs a value"; PROJECT_DIR=$2; shift 2 ;;
    --harness) [ $# -ge 2 ] || die "--harness needs a value"; HARNESS=$2; shift 2 ;;
    --apply) [ "$MODE" = select ] || die "--apply, --set, --clear, and --candidates are exclusive"; MODE=apply; shift ;;
    --set)
      [ $# -ge 2 ] || die "--set needs a value"
      { [ "$MODE" = select ] || [ "$MODE" = set ]; } || die "--apply, --set, --clear, and --candidates are exclusive"
      MODE="set"; SET_LIST="$SET_LIST ${2//,/ }"; shift 2 ;;
    --clear) [ "$MODE" = select ] || die "--apply, --set, --clear, and --candidates are exclusive"; MODE=clear; shift ;;
    --candidates) [ "$MODE" = select ] || die "--apply, --set, --clear, and --candidates are exclusive"; MODE=candidates; shift ;;
    -h|--help) usage; exit 0 ;;
    -*) die "unknown flag $1" ;;
    *) [ -z "$BRIEF" ] || die "one brief file only"; BRIEF=$1; shift ;;
  esac
done

command -v jq >/dev/null 2>&1 || die "jq required"
if [ "$MODE" = candidates ]; then
  [ -z "$BRIEF" ] || die "--candidates takes no brief file"
else
  [ -n "$BRIEF" ] || die "brief file required (see --help)"
  [ -f "$BRIEF" ] && [ -r "$BRIEF" ] || die "brief file not readable: $BRIEF"
  fm_brief_heading_present "$BRIEF" '# Task' || die "brief has no # Task section: $BRIEF"
fi

# ---- the # Required skills section -----------------------------------------------
# rewrite_section <section-file|empty>: drop any existing section, then insert
# the new one (when given) directly before the first unfenced level-1 heading
# after `# Task`, or at the end. Fence handling matches fm-brief-heading-lib.sh.
rewrite_section() {
  local section=$1 tmp="$BRIEF.skills.$$"
  # A plain redirect, not mktemp, so the rewritten brief keeps the umask mode
  # every other brief write uses.
  if ! awk -v target="$SECTION_HEADING" -v section="$section" '
    function emit_section(   line) {
      if (section == "" || inserted) return
      while ((getline line < section) > 0) print line
      close(section)
      print ""
      inserted = 1
    }
    {
      line = $0
      scan = line
      spaces = 0
      while (spaces < 3 && substr(scan, 1, 1) == " ") { scan = substr(scan, 2); spaces++ }
      marker = substr(scan, 1, 1)
      marker_len = 0
      if (marker == "`" || marker == "~") while (substr(scan, marker_len + 1, 1) == marker) marker_len++
      is_fence = marker_len >= 3
      was_fenced = fenced
      if (is_fence) {
        rest = substr(scan, marker_len + 1)
        if (!fenced) { fenced = 1; fence_marker = marker; fence_len = marker_len }
        else if (marker == fence_marker && marker_len >= fence_len && rest ~ /^[[:space:]]*$/) fenced = 0
      }
      h1 = !was_fenced && !is_fence && scan ~ /^#([ \t]|$)/
      if (h1 && skipping) skipping = 0
      if (h1 && line == target) { skipping = 1; next }
      if (skipping) next
      if (h1 && in_task) { in_task = 0; emit_section() }
      if (h1 && line == "# Task" && !seen_task) { in_task = 1; seen_task = 1 }
      print line
    }
    END { emit_section() }
  ' "$BRIEF" > "$tmp"; then
    rm -f "$tmp"
    die "could not rewrite $BRIEF"
  fi
  mv "$tmp" "$BRIEF" || { rm -f "$tmp"; die "could not write $BRIEF"; }
}

if [ "$MODE" = clear ]; then
  rewrite_section ''
  printf 'skill-select:\n  status: cleared\n  brief: written\n'
  exit 0
fi

# ---- candidates -------------------------------------------------------------------
[ -n "$HARNESS" ] || die "--harness required"
[ -n "$PROJECT" ] || [ -n "$PROJECT_DIR" ] || die "--project or --project-dir required"
if [ -z "$PROJECT_DIR" ] && [ -n "$PROJECT" ]; then
  PROJECT_DIR="$FM_HOME/projects/$PROJECT"
fi
[ -n "$PROJECT" ] || PROJECT=$(basename "$PROJECT_DIR")
[ -d "$PROJECT_DIR" ] || die "project directory not found: $PROJECT_DIR (pass --project-dir)"

claude_user_root() {
  local selection root
  selection=$(fm_worker_account_resolve claude "$CONFIG") || die "config/claude-account does not resolve"
  if [ -n "$selection" ]; then
    root=${selection#*$'\t'}
    root=${root%%$'\t'*}
    printf '%s\n' "${root:-$HOME/.claude}"
  else
    printf '%s\n' "${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
  fi
}

# skill_dirs: "<project|user><TAB><dir>" in the harness's order.
skill_dirs() {
  local d
  case "$HARNESS" in
    claude)
      printf 'user\t%s/skills\n' "$CLAUDE_USER_ROOT"
      printf 'project\t.claude/skills\n' ;;
    codex)
      for d in .agents/skills .codex/skills; do printf 'project\t%s\n' "$d"; done
      printf 'user\t%s/skills\n' "${CODEX_HOME:-$HOME/.codex}"
      printf 'user\t%s/.agents/skills\n' "$HOME" ;;
    opencode)
      for d in .opencode/skills .opencode/skill .claude/skills .agents/skills; do printf 'project\t%s\n' "$d"; done
      for d in .config/opencode/skills .config/opencode/skill .claude/skills .agents/skills; do printf 'user\t%s/%s\n' "$HOME" "$d"; done ;;
    gemini)
      for d in .gemini/skills .agents/skills; do printf 'project\t%s\n' "$d"; done
      for d in .gemini/skills .agents/skills; do printf 'user\t%s/%s\n' "$HOME" "$d"; done ;;
    devin)
      printf 'project\t.agents/skills\n'
      printf 'user\t%s/.agents/skills\n' "$HOME" ;;
    *) return 1 ;;
  esac
}

# frontmatter <SKILL.md>: "<name>US<description>US<disabled 0|1>" (US is the
# ASCII unit separator, so an empty field survives read) from the
# leading YAML block; plain, quoted, and folded or literal block scalars, with
# continuation lines joined by one space.
frontmatter() {
  awk '
    function unquote(v) {
      if (v ~ /^".*"$/) { v = substr(v, 2, length(v) - 2); gsub(/\\"/, "\"", v) }
      else if (v ~ /^\x27.*\x27$/) { v = substr(v, 2, length(v) - 2); gsub(/\x27\x27/, "\x27", v) }
      return v
    }
    function flush() {
      if (key == "name") name = unquote(val)
      else if (key == "description") desc = unquote(val)
      else if (key == "disable-model-invocation") disabled = (val == "true") ? 1 : 0
      key = ""; val = ""
    }
    NR == 1 { if ($0 != "---") exit; next }
    $0 == "---" { done = 1; exit }
    /^#/ { next }
    /^[A-Za-z0-9_-]+:/ {
      flush()
      key = $0; sub(/:.*/, "", key)
      val = $0; sub(/^[^:]*:[ \t]*/, "", val)
      if (val ~ /^[>|][-+0-9]*[ \t]*$/) val = ""
      next
    }
    key != "" {
      line = $0; sub(/^[ \t]+/, "", line); sub(/[ \t]+$/, "", line)
      if (line != "") val = (val == "" ? line : val " " line)
    }
    END {
      if (!done) exit 1
      flush()
      gsub(/[\t\r\n\037]/, " ", name); gsub(/[\t\r\n\037]/, " ", desc)
      printf "%s\037%s\037%d\n", name, desc, disabled
    }
  ' "$1"
}

# candidates_json: [{name, description, scope, path}] with path relative to the
# worktree for project skills and absolute for user skills.
candidates_json() {
  local scope dir base skill_md fm name desc disabled shown
  local -a seen=()
  {
    while IFS=$'\t' read -r scope dir; do
      if [ "$scope" = project ]; then base="$PROJECT_DIR/$dir"; else base=$dir; fi
      [ -d "$base" ] || continue
      for skill_md in "$base"/*/SKILL.md; do
        [ -f "$skill_md" ] && [ -r "$skill_md" ] || continue
        fm=$(frontmatter "$skill_md") || continue
        IFS=$'\037' read -r name desc disabled <<<"$fm"
        [ -n "$name" ] || name=$(basename "$(dirname "$skill_md")")
        [ -n "$desc" ] || continue
        [ "$disabled" = 1 ] && continue
        case " ${seen[*]:-} " in *" $name "*) continue ;; esac
        seen+=("$name")
        if [ "$scope" = project ]; then shown="$dir/${skill_md#"$base"/}"; else shown=$skill_md; fi
        jq -cn --arg name "$name" --arg description "${desc:0:1024}" --arg scope "$scope" --arg path "$shown" \
          '{name: $name, description: $description, scope: $scope, path: $path}'
      done
    done < <(skill_dirs)
  } | jq -sc '.'
}

CLAUDE_USER_ROOT=''
[ "$HARNESS" != claude ] || CLAUDE_USER_ROOT=$(claude_user_root) || exit 2
skill_dirs >/dev/null || off "harness $HARNESS has no established skill directories; nothing sent"
CANDIDATES=$(candidates_json) || die "could not read skill directories"

if [ "$MODE" = candidates ]; then
  jq -r '"skill-select candidates (\(length)):", (.[] | "  \(.name) [\(.scope)] \(.path)")' <<<"$CANDIDATES"
  exit 0
fi

# write_selection <json array of names>: render the section for those candidates.
write_selection() {
  local names=$1 section
  section=$(mktemp) || die "mktemp failed"
  jq -r --argjson names "$names" --arg heading "$SECTION_HEADING" '
    . as $c |
    $heading,
    "Load each of these skills before any other task work (after the Setup isolation check), with your tool'"'"'s skill mechanism or by reading the SKILL.md at the path shown, and follow it throughout this task:",
    ($names[] as $n | $c[] | select(.name == $n) | "- `\(.name)` (`\(.path)`)"),
    "If one of them cannot be loaded, append `blocked [at=<epoch>]: required skill <name> cannot be loaded` and stop.",
    "List the skills you loaded in your final report or PR description."
  ' <<<"$CANDIDATES" > "$section" || { rm -f "$section"; die "could not render the skills section"; }
  rewrite_section "$section"
  rm -f "$section"
}

if [ "$MODE" = set ]; then
  read -r -a SET_NAMES <<<"$SET_LIST"
  NAMES=$(printf '%s\n' "${SET_NAMES[@]}" | jq -Rsc 'split("\n") | map(select(length > 0)) | unique')
  [ "$NAMES" != '[]' ] || die "--set needs at least one skill name (use --clear to remove the section)"
  unknown=$(jq -r --argjson names "$NAMES" '[.[].name] as $have | [$names[] | select(. as $n | $have | index($n) | not)] | join(", ")' <<<"$CANDIDATES")
  [ -z "$unknown" ] || die "not a skill available to a $HARNESS worker in $PROJECT: $unknown (see --candidates)"
  write_selection "$NAMES"
  printf 'skill-select:\n  status: set\n  skills: %s\n  brief: written\n' "$(jq -r 'join(" ")' <<<"$NAMES")"
  exit 0
fi

# ---- ask Jev ----------------------------------------------------------------------
[ "$CANDIDATES" != '[]' ] || off "no skills available to a $HARNESS worker in $PROJECT; nothing sent"
fm_ts_key_resolve "$FM_HOME" || off "TYPESAFE_API_KEY absent from the environment and $FM_HOME/.env"

RESP_FILE=$(mktemp) || die "mktemp failed"
TASK_TEXT=$(mktemp) || { rm -f "$RESP_FILE"; die "mktemp failed"; }
SEND_TEXT=$(mktemp) || { rm -f "$RESP_FILE" "$TASK_TEXT"; die "mktemp failed"; }
trap 'rm -f "$RESP_FILE" "$TASK_TEXT" "$SEND_TEXT"' EXIT

emit_error() {
  echo "skill-select: error ($1)" >&2
  printf 'skill-select:\n  status: error\n  reason: %s\n  brief: unchanged\n' "$1"
  exit 0
}

fm_ts_task_text "$BRIEF" "$TASK_TEXT" || die "could not read brief: $BRIEF"
command -v curl >/dev/null 2>&1 || emit_error "curl not installed"
REQUEST=$(jq -n --rawfile brief "$TASK_TEXT" --arg project "$PROJECT" --arg model "$FM_TS_MODEL" \
  --argjson candidates "$CANDIDATES" '
  {
    model: $model,
    state: {task: {project: $project, brief: $brief}},
    questions: ($candidates | to_entries | map({
      key: ("skill_" + ((.key + 1) | tostring)),
      value: {
        type: "noul",
        instructions: "Should the agent doing `task` (read `task.brief` and `task.project`) load the skill `\(.value.name)` before starting? The skill describes itself as: \(.value.description)",
        criteria: {
          true: "The task is clearly the kind of work this skill description says it is for.",
          false: "The skill is unrelated to the task, or only loosely related."
        }
      }
    }) | from_entries)
  }')
fm_ts_never_send_check skill-select "$REQUEST" "$CONFIG/dispatch-never-send" "$SEND_TEXT"
fm_ts_post "$REQUEST" "$RESP_FILE"
[ "$FM_TS_HTTP" = 200 ] || emit_error "http $FM_TS_HTTP after $FM_TS_LAT_MS ms: $(head -c 200 "$RESP_FILE" 2>/dev/null | tr '\n' ' ')"
jq -e --argjson n "$(jq 'length' <<<"$CANDIDATES")" '
  (.answers | type) == "object" and
  ([range(1; $n + 1) | "skill_\(.)"] | sort) == (.answers | keys | sort) and
  all(.answers[]; (.noul | type) == "number" and .noul >= 0 and .noul <= 1) and
  ((has("usage") | not) or
    ((.usage | type) == "object" and (.usage.input_tokens | type) == "number" and (.usage.output_tokens | type) == "number"))' \
  "$RESP_FILE" >/dev/null 2>&1 || emit_error "response is not one yes/no answer per skill"

RESULT=$(jq -c --argjson candidates "$CANDIDATES" --arg floor "$YES_FLOOR" --argjson lat "$FM_TS_LAT_MS" '
  . as $r |
  ($candidates | to_entries | map(.value + {p: $r.answers["skill_" + ((.key + 1) | tostring)].noul})
    | sort_by(-.p) | map(. + {selected: (.p >= ($floor | tonumber))})) as $scored |
  {model: $r.model, latency_ms: $lat, tokens: ($r.usage // null), scored: $scored,
   names: [$scored[] | select(.selected) | .name]}
  | . + (if (.names | length) > 0 then {status: "clear"}
         else {status: "none", reason: "no skill reached the \($floor) floor"} end)
' "$RESP_FILE") || emit_error "selection failed"

WRITTEN=unchanged
if [ "$MODE" = apply ] && [ "$(jq -r '.status' <<<"$RESULT")" = clear ]; then
  write_selection "$(jq -c '.names' <<<"$RESULT")"
  WRITTEN=written
fi

jq -r --arg written "$WRITTEN" '
  def flat: tostring | gsub("[\t\r\n]"; " ");
  def show($value): ($value // "-") | flat;
  "skill-select:",
  "  status: \(.status)",
  "  model: \(show(.model))   latency_ms: \(show(.latency_ms))   tokens: \(show(.tokens.input_tokens))/\(show(.tokens.output_tokens))",
  (.scored[] | "  skill: \(.name | flat) p=\(.p) -> \(if .selected then "selected" else "below floor" end)"),
  (if .reason then "  reason: \(.reason)" else empty end),
  (if .status == "clear" then "  skills: \(.names | map(flat) | join(" "))" else empty end),
  "  brief: \($written)"
' <<<"$RESULT" || emit_error "output rendering failed"
exit 0
