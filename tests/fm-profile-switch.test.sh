#!/usr/bin/env bash
# bin/fm-profile-switch.sh: checkpoint mapping, cooldown, and live-switch vs relaunch.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SWITCH="$ROOT/bin/fm-profile-switch.sh"
TMP_ROOT=$(fm_test_tmproot fm-profile-switch)
mkdir -p "$TMP_ROOT"
trap 'rm -rf "$TMP_ROOT"' EXIT

RULES="$TMP_ROOT/crew-dispatch.json"
cat > "$RULES" <<'EOF'
{
  "rules": [
    {
      "when": "narrow",
      "use": [
        { "harness": "pi", "model": "zai/glm-5.3", "effort": "low", "provider": "zai" },
        { "harness": "pi", "model": "openai-codex/gpt-5.6-luna", "effort": "low", "provider": "codex" }
      ]
    },
    {
      "when": "hard",
      "use": [
        { "harness": "pi", "model": "openai-codex/gpt-5.6-sol", "effort": "xhigh", "provider": "codex" },
        { "harness": "pi", "model": "xai/grok-4.6", "effort": "xhigh", "provider": "grok" },
        { "harness": "grok", "model": "grok-4.6", "effort": "high" }
      ]
    }
  ],
  "default": [
    { "harness": "pi", "model": "zai/glm-5.3", "effort": "medium", "provider": "zai" }
  ]
}
EOF

EMPTY_HOME="$TMP_ROOT/empty-home"
mkdir -p "$EMPTY_HOME"

run_switch() {
  env -u TYPESAFE_API_KEY FM_HOME="$EMPTY_HOME" "$SWITCH" --rules "$RULES" "$@" 2>&1
}

FAKEBIN="$TMP_ROOT/fakebin"
JEV_LOG="$TMP_ROOT/jev"
mkdir -p "$FAKEBIN" "$JEV_LOG"
cat > "$FAKEBIN/curl" <<'SH'
#!/usr/bin/env bash
out=
while [ $# -gt 0 ]; do
  case "$1" in
    -o) out=$2; shift 2 ;;
    -H) [ "$2" = @/dev/fd/3 ] && cat <&3 > "${JEV_LOG:?}/header"; shift 2 ;;
    *) shift ;;
  esac
done
cat > "$JEV_LOG/request"
printf '%s' "${FAKE_JEV_RESPONSE:?}" > "$out"
printf '200'
SH
chmod +x "$FAKEBIN/curl"

run_jev() {  # <response-json> <args...>
  local response=$1
  shift
  rm -f "$JEV_LOG"/*
  PATH="$FAKEBIN:$PATH" JEV_LOG="$JEV_LOG" FAKE_JEV_RESPONSE="$response" \
    TYPESAFE_API_KEY=test-key FM_HOME="$EMPTY_HOME" \
    "$SWITCH" --rules "$RULES" "$@" 2>&1
}

test_bounded_selection() {
  local out rc
  out=$(run_switch --checkpoint complexity --current 'pi:zai/glm-5.3:low:zai' --history "$TMP_ROOT/absent")
  assert_contains "$out" 'action=hold' 'first checkpoint must hold for judgment'
  assert_contains "$out" 'firstmate judgment' 'no-key fallback must request judgment'
  out=$(run_switch --checkpoint quota --decision move-provider --rule 1 \
    --current 'pi:openai-codex/gpt-5.6-sol:xhigh:codex' \
    --selected 'pi:zai/glm-5.3:low:zai')
  rc=$?
  expect_code 1 "$rc" 'quota selection must not leave the matched capability class'
  out=$(run_switch --checkpoint quota --decision move-provider --rule 0 \
    --current 'pi:zai/glm-5.3:low:zai' \
    --candidates 'pi:zai/glm-5.3:low:zai,pi:openai-codex/gpt-5.6-luna:low:codex' \
    --selected 'pi:openai-codex/gpt-5.6-luna:low:codex')
  assert_contains "$out" 'action=live-switch' 'second comma-separated candidate must survive parsing'
  assert_contains "$out" 'model=openai-codex/gpt-5.6-luna' 'selection must match the supplied profile'
  out=$(run_switch --checkpoint complexity --decision escalate --rule 1 \
    --current 'pi:zai/glm-5.3:low:zai' --selected 'grok:grok-4.6:high:')
  assert_contains "$out" 'action=relaunch' 'native harness selection requires relaunch'
  out=$(run_switch --checkpoint phase --decision reduce --rule 0 \
    --current 'pi:openai-codex/gpt-5.6-sol:xhigh:codex' --selected 'pi:zai/glm-5.3:low:zai')
  expect_code 2 "$?" 'reduction requires an explicitly routine phase'
  pass 'bounded selection preserves rule eligibility and parses all candidates'
}

test_history_bounds() {
  local out log now
  log="$TMP_ROOT/history.log"
  now=$(date +%s)
  printf 'ts=%s req=1 status=failed\n' "$now" > "$log"
  out=$(run_switch --checkpoint quota --current 'pi:zai/glm-5.3:low:zai' --history "$log")
  assert_contains "$out" cooldown 'failed attempts must cooldown'
  printf 'ts=%s req=2 status=timeout\nts=%s req=3 status=refused\n' "$now" "$now" >> "$log"
  out=$(FM_PROFILE_SWITCH_COOLDOWN_SECS=0 run_switch --checkpoint quota \
    --current 'pi:zai/glm-5.3:low:zai' --history "$log")
  assert_contains "$out" 'retry bound' 'failed attempts must consume the retry budget'
  pass 'failed attempts enforce cooldown and retry bounds'
}

test_jev_bounds() {
  local out
  out=$(run_jev '{"answers":{"decision":{"choice":"stay","confidence":0.9}}}' \
    --checkpoint complexity --current 'pi:zai/glm-5.3:low:zai' --evidence 'tests pass')
  assert_contains "$out" 'jev=on' 'confident answer must be used'
  assert_contains "$out" 'action=hold' 'stay must hold'
  assert_equals '["escalate","stay"]' "$(jq -c '.questions.decision.criteria | keys' "$JEV_LOG/request")" 'bounded choices'
  assert_equals 'tests pass' "$(jq -r '.state.checkpoint.evidence' "$JEV_LOG/request")" 'checkpoint evidence'
  out=$(run_jev '{"answers":{"decision":{"choice":"stay","confidence":0.3}}}' \
    --checkpoint quota --current 'pi:zai/glm-5.3:low:zai')
  assert_contains "$out" 'jev=ambiguous' 'low confidence must be ambiguous'
  assert_contains "$out" 'action=hold' 'ambiguous quota must hold'
  out=$(run_jev '{"answers":{"decision":{"choice":"reduce","confidence":0.99}}}' \
    --checkpoint phase --current 'pi:zai/glm-5.3:low:zai')
  assert_contains "$out" 'jev=error' 'disallowed decision must fail'
  assert_contains "$out" 'action=hold' 'error must hold'
  mkdir -p "$EMPTY_HOME/config"
  printf 'private project\n' > "$EMPTY_HOME/config/dispatch-never-send"
  out=$(run_jev '{}' --checkpoint quota --current 'pi:zai/glm-5.3:low:zai' --evidence 'private project')
  assert_contains "$out" 'jev=never-send' 'private evidence must not be sent'
  [ ! -e "$JEV_LOG/request" ] || fail 'never-send leaked a request'
  assert_contains "$out" 'action=hold' 'never-send must hold'
  pass 'Jev remains bounded and every uncertain outcome holds'
}

test_native_provider_quota() {
  local out harness model
  for harness in grok claude; do
    case "$harness" in grok) model=grok-4.6 ;; claude) model=sonnet ;; esac
    jq -n --arg h "$harness" --arg m "$model" '{default:{harness:$h,model:$m,effort:"high"}}' > "$TMP_ROOT/native.json"
    out=$(FM_TEST_QUOTA="$(jq -nc --arg p "$harness" '{schemaVersion:5,providers:[{provider:$p,quotaSemantics:{status:"known",effectiveAvailability:[{scope:"all_models",status:"known",effectivePercentRemaining:0,runway:{status:"exhausted_now"}}]}}]}')" \
      run_switch --rules "$TMP_ROOT/native.json" --checkpoint complexity --decision escalate --rule default \
      --current 'pi:zai/glm-5.3:low:zai' --selected "$harness:$model:high:")
    assert_contains "$out" 'action=hold' 'omitted native provider must still enforce exhaustion'
    assert_contains "$out" "$harness quota exhausted" 'quota veto must use authoritative native provider'
  done
  pass 'native profiles without provider cannot bypass exhausted quota'
}

cat > "$FAKEBIN/quota-axi" <<'SH'
#!/usr/bin/env bash
if [ -n "${FM_TEST_QUOTA:-}" ]; then printf '%s\n' "$FM_TEST_QUOTA";
else printf '%s\n' '{"schemaVersion":5,"providers":[]}'; fi
SH
chmod +x "$FAKEBIN/quota-axi"
export PATH="$FAKEBIN:$PATH"
test_bounded_selection
test_history_bounds
test_jev_bounds

test_native_provider_quota
