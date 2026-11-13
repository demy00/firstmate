# shellcheck shell=bash
# typesafe.ai System One (Jev) request plumbing shared by the opt-in brief
# classifiers: bin/fm-dispatch-resolve.sh (profile) and bin/fm-skill-select.sh
# (skills).
# Usage: . bin/fm-typesafe-lib.sh
#
# This file is the single owner of what those tools have in common: the brief
# text they send, the never-send check, and the TYPESAFE_BASE selection. It also
# holds the typesafe key gate and POST that bin/fm-skill-select.sh uses;
# bin/fm-dispatch-resolve.sh selects its provider, key, and endpoint itself
# because it supports more than typesafe.
# docs/configuration.md "Typed dispatch resolution" owns the operator contract.
#
# Key handling: each caller copies TYPESAFE_API_KEY into the unexported shell
# variable TYPESAFE_API_KEY_PRIVATE and unsets TYPESAFE_API_KEY as its first
# statements, before it sources anything, so no child process inherits it.
# fm_ts_key_resolve then falls back to the home .env line. The key reaches curl
# only as a header read from file descriptor 3, never on argv, and nothing here
# logs or writes it.

# shellcheck source=bin/fm-env-lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/fm-env-lib.sh"
# shellcheck source=bin/fm-timing-lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/fm-timing-lib.sh"
# shellcheck source=bin/fm-brief-heading-lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/fm-brief-heading-lib.sh"

# Read by the sourcing scripts and set by fm_ts_post.
# shellcheck disable=SC2034
{
  FM_TS_MODEL=jev-latest
  FM_TS_BASE=https://api.typesafe.ai
  FM_TS_TIMEOUT=5
  FM_TS_HTTP='' FM_TS_LAT_MS=null
}

# fm_ts_key_resolve <home>: fill TYPESAFE_API_KEY_PRIVATE from <home>/.env when
# the environment did not supply it. The environment wins. Returns 1 when the
# key is absent from both, which every caller treats as off.
fm_ts_key_resolve() {
  if [ -z "${TYPESAFE_API_KEY_PRIVATE:-}" ]; then
    TYPESAFE_API_KEY_PRIVATE=$(fmx_env_get TYPESAFE_API_KEY "$1/.env")
  fi
  [ -n "$TYPESAFE_API_KEY_PRIVATE" ]
}

# fm_ts_base_select <home>: set FM_TS_BASE from TYPESAFE_BASE in the
# environment, else <home>/.env, when either is non-empty. An invalid value is
# a configuration error: one stderr line and exit 2. Never echo a rejected
# value: a misconfigured URL may contain credentials.
fm_ts_base_select() {
  local base=${TYPESAFE_BASE:-}
  [ -n "$base" ] || base=$(fmx_env_get TYPESAFE_BASE "$1/.env")
  [ -n "$base" ] || return 0
  command -v jq >/dev/null 2>&1 || { echo "error: jq required" >&2; exit 2; }
  jq -en --arg base "$base" '
    def ipv4:
      split(".") | length == 4 and all(.[];
        test("\\A(0|[1-9][0-9]{0,2})\\z") and (tonumber <= 255));
    def ipv6:
      # An IPv4 tail occupies two of the eight IPv6 groups.
      (if contains(".") then
        split(":") | if (.[-1] | ipv4) then .[-1] = "0:0" | join(":") else "!" end
       else . end) |
      split("::") as $sides |
      if ($sides | length) == 1 then
        test("\\A[0-9A-Fa-f]{1,4}(:[0-9A-Fa-f]{1,4}){7}\\z")
      elif ($sides | length) == 2 then
        all($sides[]; test("\\A([0-9A-Fa-f]{1,4}(:[0-9A-Fa-f]{1,4})*)?\\z")) and
        (split(":") | map(select(length > 0)) | length < 8)
      else false end;
    $base | capture("\\Ahttps?://(?<host>\\[[0-9A-Fa-f:.]+\\]|[A-Za-z0-9._-]+)(:(?<port>[0-9]+))?(?<path>/[^?#[:space:]\\\\]*)?\\z"; "i") |
    ((.path // "") | (contains("[") or contains("]")) | not) and
    (if .host | startswith("[") then .host[1:-1] | ipv6
     else true end) and
    (.port == null or (.port | tonumber | . >= 1 and . <= 65535))
  ' >/dev/null 2>&1 || {
    echo 'error: TYPESAFE_BASE must be an http(s) URL with a host and no userinfo, query, fragment, whitespace, or brackets in its path' >&2
    exit 2
  }
  while [ "${base%/}" != "$base" ]; do base=${base%/}; done
  FM_TS_BASE=$base
}

# fm_ts_task_text <brief> <out>: write the text Jev receives for a brief.
# Only the task-specific sections bin/fm-brief.sh scaffolds are sent, plus a
# scout tag from the scout contract line; the rest of a scaffolded brief is
# standard boilerplate whose safety language reads as high stakes on every task.
# A brief with neither section goes whole. Ship delivery mode is deliberately
# not sent: live runs showed it pushing routine ship briefs to the top tier.
fm_ts_task_text() {
  local brief=$1 out=$2 sections
  sections=$(
    for heading in "## Captain's intent" "## Firstmate spec"; do
      fm_brief_task_heading_present "$brief" "$heading" || continue
      printf '%s\n%s\n\n' "$heading" "$(fm_brief_task_heading_body "$brief" "$heading")"
    done
  )
  if [ -z "$sections" ]; then
    cp "$brief" "$out"
    return
  fi
  {
    if grep -qxF 'This is a SCOUT task: the deliverable is a written report, not a PR.' "$brief"; then
      printf 'Brief kind: scout (report only)\n\n'
    fi
    printf '%s\n' "$sections"
  } > "$out"
}

# fm_ts_off <label> <reason>: the off outcome, identical to an absent key:
# one stderr line, nothing on stdout, exit 0, nothing sent.
fm_ts_off() {
  echo "$1: off ($2; nothing sent)" >&2
  exit 0
}

# fm_ts_never_send_check <label> <request-json> <list> <scratch> [<endpoint>]:
# check the endpoint (default this library's System One URL) and every string
# the request carries, including strings inside JSON text such as OpenAI's
# serialized input, against the optional never-send list, so no text reaches
# the network unchecked. Each non-blank, non-# line is a literal
# matched case-insensitively, trimmed, with whitespace runs on both sides
# collapsed to one space. A match, or a list that is not a readable regular
# file, is the off outcome naming at most the list line number, never its
# value. grep's own stderr is discarded because it can echo the pattern.
fm_ts_never_send_check() {
  local label=$1 request=$2 list_path=$3 scratch=$4 endpoint=${5:-$FM_TS_BASE/v1/systemone} list value n=0 rc
  [ -e "$list_path" ] || [ -L "$list_path" ] || return 0
  { [ -f "$list_path" ] && [ -r "$list_path" ]; } \
    || fm_ts_off "$label" "$list_path is not a readable regular file"
  jq -r --arg endpoint "$endpoint" '
    $endpoint, (.. | strings | ., (try (fromjson | .. | strings) catch empty))
    | gsub("\\s+"; " ")' <<<"$request" > "$scratch" 2>/dev/null \
    || fm_ts_off "$label" "could not extract the request text to check"
  list=$(jq -Rr 'gsub("\\s+"; " ")' "$list_path" 2>/dev/null) \
    || fm_ts_off "$label" "could not read $list_path"
  while IFS= read -r value; do
    n=$((n + 1))
    value=${value# }
    value=${value% }
    case "$value" in
      ''|'#'*) continue ;;
    esac
    grep -qiF -e "$value" "$scratch" 2>/dev/null; rc=$?
    case "$rc" in
      0) fm_ts_off "$label" "brief text matches $list_path line $n" ;;
      1) ;;
      *) fm_ts_off "$label" "could not check the request text against $list_path line $n" ;;
    esac
  done <<<"$list"
}

# fm_ts_post <request-json> <resp-file>: one POST to /v1/systemone. Sets
# FM_TS_HTTP (000 on a transport failure) and FM_TS_LAT_MS for the caller.
# shellcheck disable=SC2034
fm_ts_post() {
  local t0 t1
  t0=$(fm_timing_now_ms)
  FM_TS_HTTP=$(printf '%s' "$1" | curl -sS --max-time "$FM_TS_TIMEOUT" -o "$2" -w '%{http_code}' \
    -X POST "$FM_TS_BASE/v1/systemone" -H 'Content-Type: application/json' \
    -H @/dev/fd/3 3< <(printf 'Authorization: Bearer %s\n' "$TYPESAFE_API_KEY_PRIVATE") \
    --data-binary @- 2>/dev/null) || FM_TS_HTTP=000
  t1=$(fm_timing_now_ms)
  FM_TS_LAT_MS=$(( t1 - t0 ))
}
