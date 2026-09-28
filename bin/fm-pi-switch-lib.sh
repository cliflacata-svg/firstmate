#!/usr/bin/env bash
# fm-pi-switch-lib.sh - the ONE executable owner of Firstmate's live Pi
# model/effort/provider switch protocol.
#
# Sourced by bin/fm-control.sh (the control-plane verb) and tests. Header plus
# --help on bin/fm-control.sh own caller-facing flags. This file owns:
#   - the per-task request/ack/ready/history paths
#   - request and ack JSON schema fm-pi-switch-model.v1
#   - destination validation (catalog, effort, pin, auth)
#   - idle wait, request publication, ack correlation
#   - post-confirmation metadata and history writes
#
# Live switching uses the per-task Pi extension already loaded with -e on a
# ship or scout TUI launch (bin/fm-spawn.sh). It does not switch the pane to
# RPC mode and does not replace the running harness. A harness change remains
# bin/fm-control.sh relaunch.
#
# Environment knobs (seconds unless noted):
#   FM_CONTROL_SWITCH_IDLE_WAIT   wait for a verified idle checkpoint (30)
#   FM_CONTROL_SWITCH_ACK_WAIT    wait for a matching ack after publish (20)
#   FM_CONTROL_SWITCH_READY_WAIT  wait for the session handshake (15)
#   FM_CONTROL_SWITCH_POLL        poll interval (0.25)
#   FM_PROFILE_SWITCH_COOLDOWN_SECS   selector cooldown (600)
#   FM_PROFILE_SWITCH_MAX_PER_HOUR    selector retry bound (3)
#   FM_PI_BIN                     Pi executable used for catalog/auth (pi)

FM_PI_SWITCH_SCHEMA=fm-pi-switch-model.v1

fm_pi_switch_req_path() { printf '%s/%s.model-switch.req' "$1" "$2"; }
fm_pi_switch_ack_path() { printf '%s/%s.model-switch.ack' "$1" "$2"; }
fm_pi_switch_ready_path() { printf '%s/%s.model-switch.ready' "$1" "$2"; }
fm_pi_switch_log_path() { printf '%s/%s.model-switch.log' "$1" "$2"; }

fm_pi_switch_harness_supported() {  # <harness-family>
  case "${1-}" in
    pi|pi-signed) return 0 ;;
  esac
  return 1
}

fm_pi_switch_effort_ok() {  # <effort>
  case "${1-}" in
    ''|default|low|medium|high|xhigh|max) return 0 ;;
  esac
  return 1
}

# fm_pi_switch_parse_model <model>
# Prints "provider<TAB>id" for a provider-qualified model. Returns 1 otherwise.
fm_pi_switch_parse_model() {
  local model=${1-}
  case "$model" in
    */*)
      [ -n "${model%%/*}" ] && [ -n "${model#*/}" ] || return 1
      printf '%s\t%s\n' "${model%%/*}" "${model#*/}"
      ;;
    *) return 1 ;;
  esac
}

# fm_pi_switch_catalog_row <provider> <id>
# Prints "provider<TAB>id<TAB>context" when the installed Pi catalog lists that
# exact pair. Override the listing with FM_PI_SWITCH_LISTING (file) for tests.
fm_pi_switch_catalog_row() {
  local provider=$1 id=$2 listing bin
  if [ -n "${FM_PI_SWITCH_LISTING-}" ]; then
    listing=$(cat "$FM_PI_SWITCH_LISTING")
  else
    bin=${FM_PI_BIN:-pi}
    listing=$("$bin" --list-models "$provider/$id" 2>/dev/null) || return 1
  fi
  printf '%s\n' "$listing" | awk -v p="$provider" -v i="$id" '
    NR == 1 { next }
    $1 == p && $2 == i { print $1 "\t" $2 "\t" $3; found = 1; exit }
    END { exit !found }
  '
}

# fm_pi_switch_auth_ready <provider>
# Returns 0 when Pi reports the provider ready. Override with
# FM_PI_SWITCH_AUTH_JSON (file of `pi auth check --json` output).
fm_pi_switch_auth_ready() {
  local provider=$1 out bin
  if [ -n "${FM_PI_SWITCH_AUTH_JSON-}" ]; then
    out=$(cat "$FM_PI_SWITCH_AUTH_JSON")
  else
    bin=${FM_PI_BIN:-pi}
    out=$("$bin" auth check --provider "$provider" --json --no-refresh 2>/dev/null </dev/null) || return 1
  fi
  printf '%s' "$out" | jq -e '.status == "ready"' >/dev/null 2>&1
}

fm_pi_switch_new_id() {
  printf '%s.%s.%s' "$(date +%s)" "${BASHPID:-$$}" "$RANDOM"
}

# fm_pi_switch_write_json <path> <json-object>
# Atomic replace of one JSON file.
fm_pi_switch_write_json() {
  local path=$1 json=$2 tmp
  tmp=$(mktemp "${path}.XXXXXX") || return 1
  printf '%s\n' "$json" > "$tmp" || { rm -f "$tmp"; return 1; }
  mv -f "$tmp" "$path"
}

# fm_pi_switch_write_request <state> <id> <req-id> <provider> <model-id> <effort>
fm_pi_switch_write_request() {
  local state=$1 task=$2 req_id=$3 provider=$4 model_id=$5 effort=${6-}
  local path json ts
  ts=$(date +%s)
  path=$(fm_pi_switch_req_path "$state" "$task")
  json=$(jq -nc \
    --arg schema "$FM_PI_SWITCH_SCHEMA" \
    --arg id "$req_id" \
    --arg provider "$provider" \
    --arg model_id "$model_id" \
    --arg model "$provider/$model_id" \
    --arg effort "$effort" \
    --argjson ts "$ts" \
    '{
      schema: $schema,
      id: $id,
      provider: $provider,
      model_id: $model_id,
      model: $model,
      effort: (if $effort == "" or $effort == "default" then null else $effort end),
      ts: $ts
    }') || return 1
  fm_pi_switch_write_json "$path" "$json"
}

# fm_pi_switch_read_ack <state> <id> <req-id>
# Prints the ack JSON when it exists, matches the schema, and names req-id.
# Returns 1 when absent or unmatched.
fm_pi_switch_read_ack() {
  local state=$1 task=$2 req_id=$3 path json
  path=$(fm_pi_switch_ack_path "$state" "$task")
  [ -f "$path" ] || return 1
  json=$(cat "$path") || return 1
  printf '%s' "$json" | jq -e --arg schema "$FM_PI_SWITCH_SCHEMA" --arg id "$req_id" '
    type == "object"
    and .schema == $schema
    and .id == $id
    and ((.status | type) == "string")
  ' >/dev/null 2>&1 || return 1
  printf '%s\n' "$json"
}

fm_pi_switch_append_history() {  # <state> <id> <line>
  local log
  log=$(fm_pi_switch_log_path "$1" "$2")
  printf '%s\n' "$3" >> "$log"
}

# fm_pi_switch_applied_count_since <state> <id> <epoch>
fm_pi_switch_applied_count_since() {
  local log
  log=$(fm_pi_switch_log_path "$1" "$2")
  [ -f "$log" ] || { printf '0'; return 0; }
  awk -v since="$3" '
    $0 ~ / status=applied($| )/ {
      ts = 0
      if (match($0, /ts=[0-9]+/)) ts = substr($0, RSTART + 3, RLENGTH - 3) + 0
      if (ts >= since) n++
    }
    END { print n + 0 }
  ' "$log"
}

fm_pi_switch_last_applied_ts() {
  local log
  log=$(fm_pi_switch_log_path "$1" "$2")
  [ -f "$log" ] || { printf '0'; return 0; }
  awk '
    $0 ~ / status=applied($| )/ {
      ts = 0
      if (match($0, /ts=[0-9]+/)) ts = substr($0, RSTART + 3, RLENGTH - 3) + 0
      if (ts > last) last = ts
    }
    END { print last + 0 }
  ' "$log"
}

# fm_pi_switch_meta_put <meta> <key> <value>
# Rewrites <meta> so <key> has exactly one trailing assignment.
fm_pi_switch_meta_put() {
  local meta=$1 key=$2 value=$3 tmp
  tmp=$(mktemp "${meta}.XXXXXX") || return 1
  awk -F= -v k="$key" -v v="$value" '
    $1 == k { next }
    { print }
    END { print k "=" v }
  ' "$meta" > "$tmp" || { rm -f "$tmp"; return 1; }
  mv -f "$tmp" "$meta"
}

# fm_pi_switch_confirm_meta <meta> <model> <effort> <pi-provider>
# Updates current runtime fields only. Leaves dispatch_* snapshot keys intact.
fm_pi_switch_confirm_meta() {
  local meta=$1 model=$2 effort=$3 provider=$4 ts
  ts=$(date +%s)
  fm_pi_switch_meta_put "$meta" model "$model"
  fm_pi_switch_meta_put "$meta" effort "${effort:-default}"
  if [ -n "$provider" ]; then
    fm_pi_switch_meta_put "$meta" account_provider "$provider"
  fi
  fm_pi_switch_meta_put "$meta" model_runtime "$model"
  fm_pi_switch_meta_put "$meta" model_runtime_ts "$ts"
}

# fm_pi_switch_wait_file <path> <timeout-seconds> <poll>
fm_pi_switch_wait_file() {
  local path=$1 timeout=$2 poll=$3 elapsed=0
  while :; do
    [ -f "$path" ] && return 0
    awk -v e="$elapsed" -v t="$timeout" 'BEGIN{exit !(e < t)}' || return 1
    sleep "$poll"
    elapsed=$(awk -v e="$elapsed" -v p="$poll" 'BEGIN{printf "%.3f", e + p}')
  done
}
