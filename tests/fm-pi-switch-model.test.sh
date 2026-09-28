#!/usr/bin/env bash
# fm-control.sh switch-model: live Pi session verb against a stubbed pane.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-control-lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-backend.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-pi-switch-lib.sh"

CONTROL="$ROOT/bin/fm-control.sh"
TMP_ROOT=$(fm_test_tmproot fm-pi-switch-model)
mkdir -p "$TMP_ROOT"
TMP_ROOT=$(cd "$TMP_ROOT" && pwd)
trap 'rm -rf "$TMP_ROOT"' EXIT

# Reuse the control suite's tmux stub by sourcing its helpers via a thin copy
# of the case layout those tests already proved.
make_tmux_stub() {
  local dir=$1 fb="$1/fakebin"
  mkdir -p "$fb"
  cat > "$fb/tmux" <<'SH'
#!/usr/bin/env bash
set -u
D=$FM_FAKE_DIR
case "${1:-}" in
  send-keys)
    shift
    literal=0
    while [ $# -gt 0 ]; do
      case "$1" in
        -l) literal=1; shift; continue ;;
        -t) shift 2; continue ;;
      esac
      if [ "$literal" = 1 ]; then
        printf '%s\n' "$1" >> "$D/literal"
      else
        printf '%s\n' "$1" >> "$D/keys"
      fi
      shift
    done
    ;;
  display-message)
    for a in "$@"; do
      case "$a" in
        *pane_current_command*) cat "$D/command"; printf '\n'; exit 0 ;;
        *pane_current_path*) cat "$D/cwd"; printf '\n'; exit 0 ;;
      esac
    done
    cat "$D/cwd" 2>/dev/null || printf '%s\n' /
    ;;
  list-windows)
    cat "$D/windows" 2>/dev/null || true
    ;;
  list-panes)
    printf '%s\n' "${FM_FAKE_PANE_PID:-$$}"
    ;;
  capture-pane)
    cat "$D/pane" 2>/dev/null || true
    ;;
  has-session) exit 0 ;;
  display-panes|select-window|select-pane|kill-window|kill-pane|new-window|new-session|split-window) ;;
  *) ;;
esac
exit 0
SH
  chmod +x "$fb/tmux"
}

new_case() {
  local dir="$TMP_ROOT/$1-$RANDOM"
  mkdir -p "$dir/home/state" "$dir/home/data" "$dir/home/config" "$dir/fake"
  : > "$dir/fake/literal"
  : > "$dir/fake/keys"
  printf 'zsh' > "$dir/fake/command"
  make_tmux_stub "$dir" >/dev/null
  printf '%s\n' "$dir"
}

add_task() {
  local dir=$1 id=$2 harness=${3:-pi} kind=${4:-ship}
  local home="$dir/home" proj="$dir/proj-$id" wt="$dir/wt-$id"
  fm_git_worktree "$proj" "$wt" "task-$id"
  mkdir -p "$home/data/$id"
  printf '# brief for %s\n' "$id" > "$home/data/$id/brief.md"
  {
    echo "window=fmses:fm-$id"
    echo "endpoint_task_id=$id"
    echo "worktree=$wt"
    echo "project=$proj"
    echo "harness=$harness"
    echo "kind=$kind"
    echo "mode=no-mistakes"
    echo "yolo=off"
    echo "model=zai/glm-5.3"
    echo "effort=low"
    echo "dispatch_harness=$harness"
    echo "dispatch_model=zai/glm-5.3"
    echo "dispatch_effort=low"
    echo "dispatch_provider=zai"
  } > "$home/state/$id.meta"
  printf '%s\n' "fm-$id" > "$dir/fake/windows"
  printf '%s' "$wt" > "$dir/fake/cwd"
}

run_control() {
  local dir=$1
  shift
  env PATH="$dir/fakebin:$PATH" FM_HOME="$dir/home" FM_FAKE_DIR="$dir/fake" \
    FM_CONTROL_POLL=0.01 FM_CONTROL_SWITCH_POLL=0.01 \
    FM_CONTROL_SWITCH_IDLE_WAIT="${FM_CONTROL_SWITCH_IDLE_WAIT:-1}" \
    FM_CONTROL_SWITCH_ACK_WAIT="${FM_CONTROL_SWITCH_ACK_WAIT:-1}" \
    FM_CONTROL_SWITCH_READY_WAIT="${FM_CONTROL_SWITCH_READY_WAIT:-1}" \
    FM_PI_SWITCH_LISTING="${FM_PI_SWITCH_LISTING:-}" \
    FM_PI_SWITCH_AUTH_JSON="${FM_PI_SWITCH_AUTH_JSON:-}" \
    "$CONTROL" "$@" 2>&1
}

seed_idle() {
  local dir=$1 id=$2 gen
  gen=$("$ROOT/bin/fm-busy-event.sh" arm "$dir/home/state" "$id") || return 1
  "$ROOT/bin/fm-busy-event.sh" apply "$dir/home/state" "$id" idle \
    --gen "$gen" --source pi-ext --event agent-settled >/dev/null
}

seed_busy() {
  local dir=$1 id=$2
  "$ROOT/bin/fm-busy-event.sh" arm "$dir/home/state" "$id" >/dev/null
}

write_listing() {
  local dir=$1
  cat > "$dir/listing.txt" <<'EOF'
provider      model          context  max-out  thinking  images
zai           glm-5.3        1M       131.1K   yes       no
openai-codex  gpt-5.6-luna   272K     128K     yes       yes
openai-codex  gpt-5.6-terra  272K     128K     yes       yes
xai           grok-4.5       500K     500K     yes       yes
EOF
  printf '%s' "$dir/listing.txt"
}

write_auth() {
  local dir=$1
  printf '%s\n' '{"status":"ready","provider":"openai-codex","authType":"oauth"}' > "$dir/auth.json"
  printf '%s' "$dir/auth.json"
}

ack_when_requested() {
  local dir=$1 id=$2 status=${3:-applied} model=${4:-openai-codex/gpt-5.6-luna} effort=${5:-low}
  local req ack
  req=$(fm_pi_switch_req_path "$dir/home/state" "$id")
  ack=$(fm_pi_switch_ack_path "$dir/home/state" "$id")
  (
    i=0
    while [ ! -s "$req" ] && [ "$i" -lt 500 ]; do
      sleep 0.02
      i=$((i + 1))
    done
    [ -s "$req" ] || exit 1
    req_id=$(jq -r '.id' "$req")
    [ -n "$req_id" ] && [ "$req_id" != null ] || exit 1
    jq -nc --arg id "$req_id" --arg status "$status" --arg model "$model" --arg effort "$effort" \
      '{schema:"fm-pi-switch-model.v1",id:$id,status:$status,model:$model,effort:$effort,session_id:"sess-1"}' \
      > "$ack"
  ) >/dev/null 2>&1 &
  printf '%s' "$!"
}

test_switch_model_is_a_control_verb() {
  local dir out rc
  dir=$(new_case verbs)
  add_task "$dir" t1 claude
  printf 'claude' > "$dir/fake/command"
  out=$(run_control "$dir" t1 restart); rc=$?
  expect_code 2 "$rc" "unknown verb should be a usage error"
  assert_contains "$out" "switch-model" "the allowlist should name switch-model"
  pass "switch-model is a listed control verb"
}

test_non_pi_harness_is_refused() {
  local dir out rc
  dir=$(new_case claude)
  add_task "$dir" t1 claude
  printf 'claude' > "$dir/fake/command"
  out=$(run_control "$dir" t1 switch-model --model openai-codex/gpt-5.6-luna); rc=$?
  expect_code 1 "$rc" "claude must refuse a live Pi switch"
  assert_contains "$out" "Pi session operation" "the refusal should name the Pi-only contract"
  pass "switch-model refuses a non-Pi harness"
}

test_secondmate_is_refused() {
  local dir out rc
  dir=$(new_case mate)
  add_task "$dir" t1 pi secondmate
  printf 'pi' > "$dir/fake/command"
  out=$(run_control "$dir" t1 switch-model --model openai-codex/gpt-5.6-luna); rc=$?
  expect_code 1 "$rc" "a secondmate must refuse a live switch"
  assert_contains "$out" "secondmate" "the refusal should name the task kind"
  pass "switch-model refuses a secondmate"
}

test_unsupported_model_is_refused() {
  local dir out rc listing
  dir=$(new_case nosuch)
  add_task "$dir" t1 pi
  printf 'pi' > "$dir/fake/command"
  listing=$(write_listing "$dir")
  seed_idle "$dir" t1
  out=$(FM_PI_SWITCH_LISTING="$listing" run_control "$dir" t1 switch-model --model openai-codex/not-a-model); rc=$?
  expect_code 1 "$rc" "an unlisted model must refuse"
  assert_contains "$out" "does not list" "the refusal should cite the catalog"
  [ ! -f "$(fm_pi_switch_req_path "$dir/home/state" t1)" ] \
    || fail "an unlisted model must not publish a request"
  pass "switch-model refuses an unsupported model before publishing"
}

test_busy_worker_is_deferred_not_interrupted() {
  local dir out rc listing auth
  dir=$(new_case busy)
  add_task "$dir" t1 pi
  printf 'pi' > "$dir/fake/command"
  listing=$(write_listing "$dir")
  auth=$(write_auth "$dir")
  seed_busy "$dir" t1
  : > "$(fm_pi_switch_ready_path "$dir/home/state" t1)"
  out=$(FM_PI_SWITCH_LISTING="$listing" FM_PI_SWITCH_AUTH_JSON="$auth" \
    FM_CONTROL_SWITCH_IDLE_WAIT=0.05 \
    run_control "$dir" t1 switch-model --model openai-codex/gpt-5.6-luna); rc=$?
  expect_code 1 "$rc" "a busy worker must not switch"
  assert_contains "$out" "idle checkpoint" "the refusal should demand idle"
  [ -z "$(cat "$dir/fake/keys")" ] || fail "a busy switch must send no interrupt key"
  pass "switch-model defers a busy worker instead of interrupting"
}

test_same_provider_switch_confirms_and_preserves_dispatch() {
  local dir out rc listing auth waiter meta
  dir=$(new_case same)
  add_task "$dir" t1 pi
  printf 'pi' > "$dir/fake/command"
  listing=$(write_listing "$dir")
  cat > "$dir/auth.json" <<'EOF'
{"status":"ready","provider":"zai","authType":"api_key"}
EOF
  auth="$dir/auth.json"
  seed_idle "$dir" t1
  : > "$(fm_pi_switch_ready_path "$dir/home/state" t1)"
  # Same-provider: stay on zai, raise effort.
  waiter=$(ack_when_requested "$dir" t1 applied zai/glm-5.3 medium)
  out=$(FM_PI_SWITCH_LISTING="$listing" FM_PI_SWITCH_AUTH_JSON="$auth" \
    FM_CONTROL_SWITCH_ACK_WAIT=2 \
    run_control "$dir" t1 switch-model --effort medium); rc=$?
  wait "$waiter" 2>/dev/null || true
  expect_code 0 "$rc" "a confirmed same-provider switch should succeed: $out"
  assert_contains "$out" "switched-model t1" "the outcome should name the verb"
  assert_contains "$out" "model=zai/glm-5.3" "readback model should be recorded"
  meta="$dir/home/state/t1.meta"
  [ "$(fm_meta_get "$meta" model)" = zai/glm-5.3 ] || fail "model= was not confirmed"
  [ "$(fm_meta_get "$meta" effort)" = medium ] || fail "effort= was not confirmed"
  [ "$(fm_meta_get "$meta" dispatch_model)" = zai/glm-5.3 ] || fail "dispatch snapshot was overwritten"
  [ "$(fm_meta_get "$meta" dispatch_effort)" = low ] || fail "original effort snapshot was lost"
  grep -q 'status=applied' "$(fm_pi_switch_log_path "$dir/home/state" t1)" \
    || fail "history did not record the applied switch"
  pass "same-provider switch confirms runtime readback and keeps the dispatch snapshot"
}

test_cross_provider_switch_updates_runtime_only() {
  local dir out rc listing auth waiter meta
  dir=$(new_case cross)
  add_task "$dir" t1 pi
  printf 'pi' > "$dir/fake/command"
  listing=$(write_listing "$dir")
  auth=$(write_auth "$dir")
  seed_idle "$dir" t1
  : > "$(fm_pi_switch_ready_path "$dir/home/state" t1)"
  waiter=$(ack_when_requested "$dir" t1 applied openai-codex/gpt-5.6-luna low)
  out=$(FM_PI_SWITCH_LISTING="$listing" FM_PI_SWITCH_AUTH_JSON="$auth" \
    FM_CONTROL_SWITCH_ACK_WAIT=2 \
    run_control "$dir" t1 switch-model --model openai-codex/gpt-5.6-luna --effort low); rc=$?
  wait "$waiter" 2>/dev/null || true
  expect_code 0 "$rc" "a confirmed cross-provider switch should succeed: $out"
  meta="$dir/home/state/t1.meta"
  [ "$(fm_meta_get "$meta" model)" = openai-codex/gpt-5.6-luna ] || fail "runtime model was not updated"
  [ "$(fm_meta_get "$meta" account_provider)" = openai-codex ] || fail "account_provider was not updated"
  [ "$(fm_meta_get "$meta" dispatch_model)" = zai/glm-5.3 ] || fail "original dispatch model was lost"
  [ "$(fm_meta_get "$meta" dispatch_provider)" = zai ] || fail "original dispatch provider was lost"
  pass "cross-provider switch updates runtime metadata and preserves dispatch_*"
}

test_failed_change_without_readback_keeps_old_model() {
  local dir out rc listing auth waiter meta
  dir=$(new_case fail)
  add_task "$dir" t1 pi
  printf 'pi' > "$dir/fake/command"
  listing=$(write_listing "$dir")
  auth=$(write_auth "$dir")
  seed_idle "$dir" t1
  : > "$(fm_pi_switch_ready_path "$dir/home/state" t1)"
  waiter=$(ack_when_requested "$dir" t1 failed zai/glm-5.3 low)
  # Override ack to omit a different model so metadata stays put.
  out=$(FM_PI_SWITCH_LISTING="$listing" FM_PI_SWITCH_AUTH_JSON="$auth" \
    FM_CONTROL_SWITCH_ACK_WAIT=2 \
    run_control "$dir" t1 switch-model --model openai-codex/gpt-5.6-luna); rc=$?
  wait "$waiter" 2>/dev/null || true
  expect_code 1 "$rc" "a failed switch should refuse"
  meta="$dir/home/state/t1.meta"
  [ "$(fm_meta_get "$meta" model)" = zai/glm-5.3 ] || fail "failed switch must keep the old model"
  pass "a failed switch without a new readback keeps the recorded model"
}

test_partial_success_reconciles_to_readback() {
  local dir out rc listing auth waiter meta
  dir=$(new_case partial)
  add_task "$dir" t1 pi
  printf 'pi' > "$dir/fake/command"
  listing=$(write_listing "$dir")
  auth=$(write_auth "$dir")
  seed_idle "$dir" t1
  : > "$(fm_pi_switch_ready_path "$dir/home/state" t1)"
  waiter=$(ack_when_requested "$dir" t1 refused openai-codex/gpt-5.6-luna low)
  out=$(FM_PI_SWITCH_LISTING="$listing" FM_PI_SWITCH_AUTH_JSON="$auth" \
    FM_CONTROL_SWITCH_ACK_WAIT=2 \
    run_control "$dir" t1 switch-model --model openai-codex/gpt-5.6-luna --effort medium); rc=$?
  wait "$waiter" 2>/dev/null || true
  expect_code 1 "$rc" "a partial switch should refuse overall"
  meta="$dir/home/state/t1.meta"
  [ "$(fm_meta_get "$meta" model)" = openai-codex/gpt-5.6-luna ] \
    || fail "partial success must reconcile metadata to the runtime readback"
  pass "partial success reconciles metadata to the runtime model"
}

test_restart_recovery_reads_last_confirmed_profile() {
  local dir meta
  dir=$(new_case recover)
  add_task "$dir" t1 pi
  meta="$dir/home/state/t1.meta"
  fm_pi_switch_confirm_meta "$meta" openai-codex/gpt-5.6-luna medium openai-codex
  [ "$(fm_meta_get "$meta" model)" = openai-codex/gpt-5.6-luna ] || fail "confirmed model missing"
  [ "$(fm_meta_get "$meta" dispatch_model)" = zai/glm-5.3 ] || fail "dispatch snapshot missing after confirm"
  [ "$(fm_meta_get "$meta" model_runtime)" = openai-codex/gpt-5.6-luna ] || fail "model_runtime missing"
  pass "recovery reads the last confirmed profile beside the original dispatch snapshot"
}

test_missing_handshake_refuses() {
  local dir out rc listing auth
  dir=$(new_case ready)
  add_task "$dir" t1 pi
  printf 'pi' > "$dir/fake/command"
  listing=$(write_listing "$dir")
  auth=$(write_auth "$dir")
  seed_idle "$dir" t1
  out=$(FM_PI_SWITCH_LISTING="$listing" FM_PI_SWITCH_AUTH_JSON="$auth" \
    FM_CONTROL_SWITCH_READY_WAIT=0.05 \
    run_control "$dir" t1 switch-model --model openai-codex/gpt-5.6-luna); rc=$?
  expect_code 1 "$rc" "a worker without the handshake must refuse"
  assert_contains "$out" "handshake" "the refusal should name the missing session handshake"
  pass "switch-model refuses when the Pi session handshake is missing"
}

test_harness_flag_stays_relaunch_only() {
  local dir out rc
  dir=$(new_case flags)
  add_task "$dir" t1 pi
  printf 'pi' > "$dir/fake/command"
  out=$(run_control "$dir" t1 switch-model --harness grok --model openai-codex/gpt-5.6-luna); rc=$?
  expect_code 1 "$rc" "--harness must not apply to switch-model"
  assert_contains "$out" "relaunch" "the refusal should point at relaunch"
  pass "switch-model refuses --harness rather than changing runtime"
}

test_switch_model_is_a_control_verb
test_non_pi_harness_is_refused
test_secondmate_is_refused
test_unsupported_model_is_refused
test_busy_worker_is_deferred_not_interrupted
test_same_provider_switch_confirms_and_preserves_dispatch
test_cross_provider_switch_updates_runtime_only
test_failed_change_without_readback_keeps_old_model
test_partial_success_reconciles_to_readback
test_restart_recovery_reads_last_confirmed_profile
test_missing_handshake_refuses
test_harness_flag_stays_relaunch_only
