#!/usr/bin/env bash
# Opt-in live smoke: spawn a real Pi worker through bin/fm-spawn.sh, switch
# model in the same session, and prove the task id, session, isolated copy,
# an on-disk edit, and a distinctive conversation detail survive.
#
# Spends a small number of tokens on the cheapest verified subscription
# profiles (zai/glm-5.3 and xai/grok-4.5). Run with FM_PI_SWITCH_LIVE=1.
# Cleans up the smoke endpoint and worktree.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_live_gate opt-in FM_PI_SWITCH_LIVE pi tmux jq

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-backend.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-pi-switch-lib.sh"

TASK=smoke-pi-switch-$$
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-pi-switch-live.XXXXXX") || fail "could not create lab"
SOCKET_DIR=
SPAWNED=0
WT=

cleanup() {
  if [ "$SPAWNED" = 1 ]; then
    FM_HOME="$LAB" "$ROOT/bin/fm-control.sh" "$TASK" exit >/dev/null 2>&1 || true
  fi
  if [ -n "$SOCKET_DIR" ]; then
    TMUX_TMPDIR="$SOCKET_DIR" tmux kill-server >/dev/null 2>&1 || true
  fi
  if [ -n "$WT" ] && [ -d "$WT" ]; then
    command -v treehouse >/dev/null 2>&1 && treehouse return "$WT" >/dev/null 2>&1 || true
  fi
  chmod -R u+w "$LAB" 2>/dev/null || true
  rm -rf "$LAB"
  if [ -n "$WT" ] && [ -d "$WT" ]; then
    rm -rf "$WT"
  fi
}
trap cleanup EXIT

"$ROOT/bin/fm-lab-home.sh" create "$LAB" >/dev/null
SOCKET_DIR=$("$ROOT/bin/fm-lab-home.sh" tmux-dir "$LAB")
printf 'manual\n' > "$LAB/config/backlog-backend"
printf 'tmux\n' > "$LAB/config/backend"

PROJ="$LAB/projects/smoke"
mkdir -p "$PROJ"
git -C "$PROJ" init -q -b main
git -C "$PROJ" config user.email 'smoke@example.invalid'
git -C "$PROJ" config user.name 'smoke'
printf 'smoke project\n' > "$PROJ/README.md"
git -C "$PROJ" add README.md
git -C "$PROJ" commit -qm 'fixture: smoke project'

mkdir -p "$LAB/data/$TASK"
TOKEN="PINECONE-$(date +%s)"
STATUS="$LAB/state/$TASK.status"
cat > "$LAB/data/$TASK/brief.md" <<EOF
# Task
## Captain's intent
Live-switch smoke. Remember the codeword $TOKEN.
Create a file named SMOKE.txt in the project containing exactly that codeword.
Then append \`working [at=<epoch>]: smoke-idle $TOKEN\` to $STATUS and wait.

## Firstmate spec
Do not change models yourself. Keep the rest of the repository untouched.
EOF

export FM_HOME="$LAB" TMUX_TMPDIR="$SOCKET_DIR"
FM_HOME="$LAB" "$ROOT/bin/fm-spawn.sh" "$TASK" "$PROJ" --scout --harness pi \
  --model zai/glm-5.3 --effort low --backend tmux \
  || fail "fm-spawn.sh failed to launch the Pi smoke worker"
SPAWNED=1
WT=$(fm_meta_get "$LAB/state/$TASK.meta" worktree)
[ -n "$WT" ] || fail "spawn did not record a worktree"
SESSION_BEFORE=$(fm_meta_get "$LAB/state/$TASK.meta" window)

idle_line=
for _ in $(seq 1 90); do
  if [ -f "$STATUS" ] && grep -q "smoke-idle $TOKEN" "$STATUS"; then
    idle_line=$(grep "smoke-idle $TOKEN" "$STATUS" | tail -1)
    break
  fi
  sleep 2
done
[ -n "$idle_line" ] || fail "Pi worker did not report smoke-idle with the codeword"

[ -f "$WT/SMOKE.txt" ] || fail "the distinctive edit SMOKE.txt did not land"
grep -Fq "$TOKEN" "$WT/SMOKE.txt" || fail "SMOKE.txt does not contain the codeword"

model_before=$(fm_meta_get "$LAB/state/$TASK.meta" model)
[ "$model_before" = zai/glm-5.3 ] || fail "spawn recorded model=$model_before"

# Same-provider: raise effort on zai. glm-5.3 clamps unsupported levels, so
# request high and require the runtime readback, not the requested token.
FM_HOME="$LAB" "$ROOT/bin/fm-control.sh" "$TASK" switch-model --effort high \
  || fail "same-provider live switch failed"
model_mid=$(fm_meta_get "$LAB/state/$TASK.meta" model)
effort_mid=$(fm_meta_get "$LAB/state/$TASK.meta" effort)
[ "$model_mid" = zai/glm-5.3 ] || fail "same-provider switch changed model to $model_mid"
[ "$effort_mid" = high ] || fail "same-provider switch recorded effort=$effort_mid instead of the confirmed high"

# Cross-provider: zai -> xai SuperGrok (subscription OAuth, not OpenRouter).
FM_HOME="$LAB" "$ROOT/bin/fm-control.sh" "$TASK" switch-model \
  --model xai/grok-4.5 --effort low \
  || fail "cross-provider live switch to xai failed"
model_after=$(fm_meta_get "$LAB/state/$TASK.meta" model)
[ "$model_after" = xai/grok-4.5 ] || fail "cross-provider switch recorded $model_after"
SESSION_AFTER=$(fm_meta_get "$LAB/state/$TASK.meta" window)
[ "$SESSION_BEFORE" = "$SESSION_AFTER" ] || fail "endpoint changed from $SESSION_BEFORE to $SESSION_AFTER"
[ "$(fm_meta_get "$LAB/state/$TASK.meta" dispatch_model)" = zai/glm-5.3 ] \
  || fail "original dispatch snapshot was lost"
[ -f "$WT/SMOKE.txt" ] || fail "the edit disappeared after the switch"
grep -Fq "$TOKEN" "$WT/SMOKE.txt" || fail "the codeword disappeared from the edit"

log=$(fm_pi_switch_log_path "$LAB/state" "$TASK")
grep -q 'status=applied' "$log" || fail "switch history has no applied line"
ack=$(fm_pi_switch_ack_path "$LAB/state" "$TASK")
session_id=$(jq -r '.session_id // empty' "$ack")
[ -n "$session_id" ] || fail "the extension did not report a session id"

pass "Pi live switch kept task $TASK session $session_id worktree $WT edit and codeword $TOKEN; model $model_before -> $model_after"
