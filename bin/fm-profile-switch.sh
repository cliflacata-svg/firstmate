#!/usr/bin/env bash
# fm-profile-switch.sh - choose a live Pi switch or a harness relaunch from
# crew-dispatch.json at a bounded checkpoint.
#
# Usage:
#   fm-profile-switch.sh --checkpoint <complexity|stall|phase|quota>
#                        --current <harness:model:effort[:provider]>
#                        --rules <crew-dispatch.json>
#                        [--history <model-switch.log>]
#                        [--routine]
#                        [--candidates <harness:model:effort[:provider],...>]
#                        [--evidence <checkpoint text>]
#
# Prints one action block:
#   action=hold|live-switch|relaunch
#   jev=off|unused|on|ambiguous|error|never-send
#   reason=<text>
#   harness=... model=... effort=... provider=...   (when not hold)
#
# Checkpoint mapping in code (firstmate's judged path):
#   complexity|stall -> escalate
#   quota            -> move-provider
#   phase            -> stay, or reduce when --routine is passed
#
# Jev (typesafe System One) is opt-in with the same TYPESAFE_API_KEY gate as
# bin/fm-dispatch-resolve.sh (environment, else $FM_HOME/.env). When the key
# is present and no cooldown or retry bound holds, one POST classifies the
# checkpoint kind, --routine, and --evidence text among only the decisions
# that checkpoint allows:
#   complexity|stall -> escalate|stay
#   quota            -> move-provider|stay
#   phase            -> escalate|stay, plus reduce with --routine
# Jev never sees or returns model IDs. jev=on means its answer cleared a 0.6
# confidence floor and was used; ambiguous, error, or never-send (a match in
# config/dispatch-never-send; nothing sent) fall back to the mapping above.
# Without the key there is no network call and jev=off.
#
# Eligible destinations are the --candidates list when given, otherwise every
# profile in --rules. Capability, authentication, quota, and context checks
# stay in this script and bin/fm-pi-switch-lib.sh; Jev does not select among
# them. A Pi destination on a Pi current harness is live-switch; any other
# harness change is relaunch. Cooldown and per-hour retry bounds are owned
# here (FM_PROFILE_SWITCH_COOLDOWN_SECS, FM_PROFILE_SWITCH_MAX_PER_HOUR).
set -eu

TYPESAFE_API_KEY_PRIVATE=${TYPESAFE_API_KEY:-}
export -n TYPESAFE_API_KEY_PRIVATE 2>/dev/null || true
unset TYPESAFE_API_KEY

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_HOME="${FM_HOME:-$(cd "$SCRIPT_DIR/.." && pwd)}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
# shellcheck source=bin/fm-pi-switch-lib.sh
. "$SCRIPT_DIR/fm-pi-switch-lib.sh"
# shellcheck source=bin/fm-env-lib.sh
. "$SCRIPT_DIR/fm-env-lib.sh"

TS_MODEL=jev-latest
TS_BASE=https://api.typesafe.ai
TS_TIMEOUT=5
JEV_FLOOR=0.6

usage() {
  sed -n '2,${/^#/!q;p;}' "$0" | sed 's/^# \{0,1\}//'
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
esac

CHECKPOINT=
CURRENT=
RULES=
HISTORY=
ROUTINE=0
CANDIDATES=
EVIDENCE=

want=
for arg in "$@"; do
  if [ -n "$want" ]; then
    case "$want" in
      checkpoint) CHECKPOINT=$arg ;;
      current) CURRENT=$arg ;;
      rules) RULES=$arg ;;
      history) HISTORY=$arg ;;
      candidates) CANDIDATES=$arg ;;
      evidence) EVIDENCE=$arg ;;
    esac
    want=
    continue
  fi
  case "$arg" in
    --checkpoint) want=checkpoint ;;
    --checkpoint=*) CHECKPOINT=${arg#--checkpoint=} ;;
    --current) want=current ;;
    --current=*) CURRENT=${arg#--current=} ;;
    --rules) want=rules ;;
    --rules=*) RULES=${arg#--rules=} ;;
    --history) want=history ;;
    --history=*) HISTORY=${arg#--history=} ;;
    --candidates) want=candidates ;;
    --candidates=*) CANDIDATES=${arg#--candidates=} ;;
    --evidence) want=evidence ;;
    --evidence=*) EVIDENCE=${arg#--evidence=} ;;
    --routine) ROUTINE=1 ;;
    *) echo "error: unexpected argument '$arg'" >&2; exit 2 ;;
  esac
done
[ -z "$want" ] || { echo "error: --$want requires a value" >&2; exit 2; }

case "$CHECKPOINT" in
  complexity|stall|phase|quota) ;;
  *) echo "error: --checkpoint must be complexity, stall, phase, or quota" >&2; exit 2 ;;
esac
[ -n "$CURRENT" ] || { echo "error: --current is required" >&2; exit 2; }
[ -n "$RULES" ] && [ -f "$RULES" ] || { echo "error: --rules must be an existing crew-dispatch.json" >&2; exit 2; }

IFS=':' read -r CUR_HARNESS CUR_MODEL CUR_EFFORT CUR_PROVIDER <<EOF
$CURRENT
EOF
[ -n "$CUR_HARNESS" ] || { echo "error: --current needs harness:model:effort" >&2; exit 2; }

if [ -z "$TYPESAFE_API_KEY_PRIVATE" ]; then
  TYPESAFE_API_KEY_PRIVATE=$(fmx_env_get TYPESAFE_API_KEY "$FM_HOME/.env")
fi
if [ -n "$TYPESAFE_API_KEY_PRIVATE" ]; then
  JEV=unused
else
  JEV=off
fi

emit() {  # <action> <reason> [harness model effort provider]
  local action=$1 reason=$2
  printf 'action=%s\n' "$action"
  printf 'jev=%s\n' "$JEV"
  printf 'reason=%s\n' "$reason"
  if [ "$#" -ge 6 ]; then
    printf 'harness=%s\n' "$3"
    printf 'model=%s\n' "$4"
    printf 'effort=%s\n' "$5"
    printf 'provider=%s\n' "$6"
  fi
}

decision=stay
case "$CHECKPOINT" in
  complexity|stall) decision=escalate ;;
  quota) decision=move-provider ;;
  phase)
    if [ "$ROUTINE" = 1 ]; then
      decision=reduce
    else
      decision=stay
    fi
    ;;
esac

if [ -n "$HISTORY" ]; then
  now=$(date +%s)
  cooldown=${FM_PROFILE_SWITCH_COOLDOWN_SECS:-600}
  max_hour=${FM_PROFILE_SWITCH_MAX_PER_HOUR:-3}
  last=$(awk '
    $0 ~ / status=applied($| )/ {
      ts = 0
      if (match($0, /ts=[0-9]+/)) ts = substr($0, RSTART + 3, RLENGTH - 3) + 0
      if (ts > last) last = ts
    }
    END { print last + 0 }
  ' "$HISTORY")
  if [ "$last" -gt 0 ] && [ $((now - last)) -lt "$cooldown" ]; then
    emit hold "cooldown $((cooldown - (now - last)))s remaining"
    exit 0
  fi
  hour_ago=$((now - 3600))
  count=$(awk -v since="$hour_ago" '
    $0 ~ / status=applied($| )/ {
      ts = 0
      if (match($0, /ts=[0-9]+/)) ts = substr($0, RSTART + 3, RLENGTH - 3) + 0
      if (ts >= since) n++
    }
    END { print n + 0 }
  ' "$HISTORY")
  if [ "$count" -ge "$max_hour" ]; then
    emit hold "retry bound $max_hour switches in the last hour"
    exit 0
  fi
fi

# Succeeds when the request must not be sent: a never-send line matches one
# of its strings, or the list exists but cannot be checked.
never_send_hit() {  # <request-json>
  local list="$CONFIG/dispatch-never-send" text lines value rc
  [ -e "$list" ] || [ -L "$list" ] || return 1
  { [ -f "$list" ] && [ -r "$list" ]; } || return 0
  text=$(jq -r '.. | strings | gsub("\\s+"; " ")' <<<"$1" 2>/dev/null) || return 0
  lines=$(jq -Rr 'gsub("\\s+"; " ")' "$list" 2>/dev/null) || return 0
  while IFS= read -r value; do
    value=${value# }
    value=${value% }
    case "$value" in
      ''|'#'*) continue ;;
    esac
    rc=0
    printf '%s\n' "$text" | grep -qiF -e "$value" 2>/dev/null || rc=$?
    [ "$rc" = 1 ] || return 0
  done <<<"$lines"
  return 1
}

jev_classify() {
  local allowed request resp http answer
  allowed='["escalate","stay"]'
  case "$CHECKPOINT" in
    quota) allowed='["move-provider","stay"]' ;;
    phase) [ "$ROUTINE" = 1 ] && allowed='["escalate","reduce","stay"]' ;;
  esac
  request=$(jq -n --arg model "$TS_MODEL" --arg kind "$CHECKPOINT" \
    --argjson routine "$([ "$ROUTINE" = 1 ] && echo true || echo false)" \
    --arg evidence "$EVIDENCE" --argjson allowed "$allowed" '
    {
      escalate: "The evidence shows the current worker profile is inadequate for the remaining work: newly discovered complexity or repeated failure without progress.",
      "move-provider": "The current provider quota is constrained enough that the worker should continue on another provider of equal capability.",
      reduce: "The remaining phase is explicitly routine and independently verifiable, so a lower-cost profile is sufficient.",
      stay: "The evidence does not justify changing the worker profile now."
    } as $all |
    {
      model: $model,
      state: {checkpoint: {kind: $kind, routine: $routine, evidence: $evidence}},
      questions: {
        decision: {
          type: "choice",
          instructions: "A coding worker reported `checkpoint`. Which ONE decision does its evidence support? Prefer `stay` unless the evidence clearly supports another option.",
          criteria: ($all | with_entries(select(.key as $k | $allowed | index($k))))
        }
      }
    }') || { JEV=error; return; }
  if never_send_hit "$request"; then
    JEV=never-send
    return
  fi
  command -v curl >/dev/null 2>&1 || { JEV=error; return; }
  resp=$(mktemp) || { JEV=error; return; }
  http=$(printf '%s' "$request" | curl -sS --max-time "$TS_TIMEOUT" -o "$resp" -w '%{http_code}' \
    -X POST "$TS_BASE/v1/systemone" -H 'Content-Type: application/json' \
    -H @/dev/fd/3 3< <(printf 'Authorization: Bearer %s\n' "$TYPESAFE_API_KEY_PRIVATE") \
    --data-binary @- 2>/dev/null) || http=000
  answer=$(jq -r --argjson allowed "$allowed" --argjson floor "$JEV_FLOOR" '
    .answers.decision as $a
    | if ($a.choice | type) != "string" or ($allowed | index($a.choice)) == null
         or ($a.confidence | type) != "number" then "error"
      elif $a.confidence < $floor then "ambiguous"
      else "on " + $a.choice end
  ' "$resp" 2>/dev/null) || answer=error
  rm -f "$resp"
  [ "$http" = 200 ] || answer=error
  case "$answer" in
    on\ *) JEV=on; decision=${answer#on } ;;
    ambiguous) JEV=ambiguous ;;
    *) JEV=error ;;
  esac
}

if [ -n "$TYPESAFE_API_KEY_PRIVATE" ]; then
  jev_classify
fi

if [ "$decision" = stay ]; then
  emit hold "checkpoint $CHECKPOINT does not authorize a profile change"
  exit 0
fi

effort_rank() {
  case "$1" in
    low) printf '1' ;;
    medium) printf '2' ;;
    high) printf '3' ;;
    xhigh) printf '4' ;;
    max) printf '5' ;;
    *) printf '2' ;;
  esac
}

profiles_json=$(jq -c '
  def profiles($value):
    if ($value | type) == "array" then $value
    elif ($value | type) == "object" then [$value]
    else [] end;
  [((.rules // [])[] | profiles(.use)[]), (profiles(.default // null)[])]
  | map(select((.harness | type) == "string" and (.harness | length) > 0))
' "$RULES") || {
  echo "error: malformed rules file: $RULES" >&2
  exit 1
}

if [ -n "$CANDIDATES" ]; then
  profiles_json=$(printf '%s' "$CANDIDATES" | awk -F: -v OFS= '
    BEGIN { printf "[" }
    {
      if (NR > 1) printf ","
      harness=$1; model=$2; effort=$3; provider=$4
      printf "{\"harness\":\"%s\"", harness
      if (model != "") printf ",\"model\":\"%s\"", model
      if (effort != "") printf ",\"effort\":\"%s\"", effort
      if (provider != "") printf ",\"provider\":\"%s\"", provider
      printf "}"
    }
    END { printf "]" }
  ')
fi

cur_rank=$(effort_rank "${CUR_EFFORT:-medium}")

pick=$(printf '%s' "$profiles_json" | jq -c \
  --arg decision "$decision" \
  --arg cur_h "$CUR_HARNESS" \
  --arg cur_m "$CUR_MODEL" \
  --arg cur_e "${CUR_EFFORT:-}" \
  --arg cur_p "${CUR_PROVIDER:-}" \
  --argjson cur_rank "$cur_rank" '
  def rank($e):
    if $e == "low" then 1
    elif $e == "medium" then 2
    elif $e == "high" then 3
    elif $e == "xhigh" then 4
    elif $e == "max" then 5
    else 2 end;
  def ident($p):
    ($p.harness // "") + ":" + ($p.model // "") + ":" + ($p.effort // "") + ":" + ($p.provider // "");
  def current($p):
    ident($p) == ($cur_h + ":" + $cur_m + ":" + $cur_e + ":" + $cur_p)
    or ($p.harness == $cur_h and ($p.model // "") == $cur_m and ($p.effort // "") == $cur_e);
  [ .[] | select(current(.) | not) ] as $rest
  | if $decision == "escalate" then
      ($rest | map(select(rank(.effort // "medium") > $cur_rank))) as $up
      | if ($up | length) > 0 then $up[0]
        else ($rest | map(select(.harness != $cur_h)) | .[0] // null) end
    elif $decision == "move-provider" then
      ($rest | map(select(
        (.harness == $cur_h)
        and rank(.effort // "medium") >= $cur_rank
        and ((.provider // "") != $cur_p)
      ))) as $cross
      | if ($cross | length) > 0 then $cross[0]
        else ($rest | map(select((.provider // "") != $cur_p or .harness != $cur_h)) | .[0] // null) end
    elif $decision == "reduce" then
      ($rest | map(select(rank(.effort // "medium") < $cur_rank)) | sort_by(rank(.effort // "medium"))) as $down
      | if ($down | length) > 0 then $down[0]
        else null end
    else null end
')

if [ -z "$pick" ] || [ "$pick" = null ]; then
  emit hold "no eligible destination for $decision from $CURRENT"
  exit 0
fi

PICK_HARNESS=$(printf '%s' "$pick" | jq -r '.harness')
PICK_MODEL=$(printf '%s' "$pick" | jq -r '.model // empty')
PICK_EFFORT=$(printf '%s' "$pick" | jq -r '.effort // empty')
PICK_PROVIDER=$(printf '%s' "$pick" | jq -r '.provider // empty')

if [ "$PICK_HARNESS" = "$CUR_HARNESS" ] && { [ "$PICK_HARNESS" = pi ] || [ "$PICK_HARNESS" = pi-signed ]; }; then
  emit live-switch "checkpoint $CHECKPOINT decision $decision" \
    "$PICK_HARNESS" "$PICK_MODEL" "$PICK_EFFORT" "$PICK_PROVIDER"
  exit 0
fi

emit relaunch "checkpoint $CHECKPOINT decision $decision requires a harness change" \
  "$PICK_HARNESS" "$PICK_MODEL" "$PICK_EFFORT" "$PICK_PROVIDER"
