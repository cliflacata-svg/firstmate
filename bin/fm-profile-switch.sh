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
#
# Prints one action block:
#   action=hold|live-switch|relaunch
#   jev=off|unused
#   reason=<text>
#   harness=... model=... effort=... provider=...   (when not hold)
#
# Jev (typesafe System One) is optional classification among the allowed
# decisions escalate|move-provider|reduce|stay. It never invents model IDs.
# When TYPESAFE_API_KEY is absent this tool maps the checkpoint in code:
#   complexity|stall -> escalate
#   quota            -> move-provider
#   phase            -> stay, or reduce when --routine is passed
#
# Eligible destinations are the --candidates list when given, otherwise every
# profile in --rules. Capability, authentication, quota, and context checks
# stay in this script and bin/fm-pi-switch-lib.sh; Jev does not select among
# them. A Pi destination on a Pi current harness is live-switch; any other
# harness change is relaunch. Cooldown and per-hour retry bounds are owned
# here (FM_PROFILE_SWITCH_COOLDOWN_SECS, FM_PROFILE_SWITCH_MAX_PER_HOUR).
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-pi-switch-lib.sh
. "$SCRIPT_DIR/fm-pi-switch-lib.sh"

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

want=
for arg in "$@"; do
  if [ -n "$want" ]; then
    case "$want" in
      checkpoint) CHECKPOINT=$arg ;;
      current) CURRENT=$arg ;;
      rules) RULES=$arg ;;
      history) HISTORY=$arg ;;
      candidates) CANDIDATES=$arg ;;
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

emit() {  # <action> <reason> [harness model effort provider]
  local action=$1 reason=$2
  printf 'action=%s\n' "$action"
  if [ -n "${TYPESAFE_API_KEY:-}" ]; then
    printf 'jev=unused\n'
  else
    printf 'jev=off\n'
  fi
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
