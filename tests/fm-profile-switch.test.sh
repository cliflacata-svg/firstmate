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

run_switch() {
  env -u TYPESAFE_API_KEY "$SWITCH" --rules "$RULES" "$@" 2>&1
}

test_complexity_escalates_to_live_switch() {
  local out
  out=$(run_switch --checkpoint complexity \
    --current 'pi:zai/glm-5.3:low:zai')
  assert_contains "$out" "action=live-switch" "complexity should stay on Pi"
  assert_contains "$out" "jev=off" "absent Jev key must report off"
  assert_contains "$out" "effort=xhigh" "escalate should pick a stronger effort"
  assert_contains "$out" "model=openai-codex/gpt-5.6-sol" "escalate should pick the stronger Pi profile"
  pass "complexity escalates inside Pi as a live switch"
}

test_quota_moves_provider() {
  local out
  out=$(run_switch --checkpoint quota \
    --current 'pi:zai/glm-5.3:low:zai')
  assert_contains "$out" "action=live-switch" "quota should stay a live switch when Pi remains"
  assert_contains "$out" "provider=codex" "quota should move to the other provider"
  pass "quota moves across Pi providers as a live switch"
}

test_phase_without_routine_holds() {
  local out
  out=$(run_switch --checkpoint phase \
    --current 'pi:zai/glm-5.3:low:zai')
  assert_contains "$out" "action=hold" "phase without --routine must not reduce"
  pass "phase without --routine holds"
}

test_routine_phase_reduces() {
  local out
  out=$(run_switch --checkpoint phase --routine \
    --current 'pi:openai-codex/gpt-5.6-sol:xhigh:codex')
  assert_contains "$out" "action=live-switch" "routine phase may reduce on Pi"
  assert_contains "$out" "effort=low" "reduce should pick a lower effort"
  pass "routine phase reduces inside Pi"
}

test_xai_stays_live_switch() {
  local out
  out=$(run_switch --checkpoint quota \
    --current 'pi:zai/glm-5.3:low:zai' \
    --candidates 'pi:xai/grok-4.5:low:grok')
  assert_contains "$out" "action=live-switch" "xai on Pi is a live switch"
  assert_contains "$out" "model=xai/grok-4.5" "quota should move to the xai Pi profile"
  pass "xai SuperGrok on Pi is a live switch, not a native Grok relaunch"
}

test_harness_change_is_relaunch() {
  local out
  out=$(run_switch --checkpoint complexity \
    --current 'pi:openai-codex/gpt-5.6-sol:xhigh:codex' \
    --candidates 'grok:grok-4.6:high:')
  assert_contains "$out" "action=relaunch" "a Grok destination must relaunch"
  assert_contains "$out" "harness=grok" "relaunch should name Grok"
  pass "a non-Pi destination is relaunch, not a live switch"
}

test_cooldown_holds() {
  local out log
  log="$TMP_ROOT/history.log"
  printf 'ts=%s req=1 from=a to=b status=applied\n' "$(date +%s)" > "$log"
  out=$(FM_PROFILE_SWITCH_COOLDOWN_SECS=600 run_switch --checkpoint complexity \
    --current 'pi:zai/glm-5.3:low:zai' --history "$log")
  assert_contains "$out" "action=hold" "a fresh applied switch must cooldown"
  assert_contains "$out" "cooldown" "the reason should name cooldown"
  pass "cooldown prevents oscillation"
}

test_retry_bound_holds() {
  local out log now
  log="$TMP_ROOT/bound.log"
  now=$(date +%s)
  {
    printf 'ts=%s req=1 from=a to=b status=applied\n' "$now"
    printf 'ts=%s req=2 from=a to=b status=applied\n' "$now"
    printf 'ts=%s req=3 from=a to=b status=applied\n' "$now"
  } > "$log"
  out=$(FM_PROFILE_SWITCH_COOLDOWN_SECS=0 FM_PROFILE_SWITCH_MAX_PER_HOUR=3 \
    run_switch --checkpoint complexity \
    --current 'pi:zai/glm-5.3:low:zai' --history "$log")
  assert_contains "$out" "action=hold" "three switches in an hour must hold"
  assert_contains "$out" "retry bound" "the reason should name the retry bound"
  pass "retry bound prevents oscillation"
}

test_complexity_escalates_to_live_switch
test_quota_moves_provider
test_phase_without_routine_holds
test_routine_phase_reduces
test_xai_stays_live_switch
test_harness_change_is_relaunch
test_cooldown_holds
test_retry_bound_holds
