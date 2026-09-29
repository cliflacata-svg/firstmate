#!/usr/bin/env bash
# Opt-in live smoke: spawn a real Pi worker through bin/fm-spawn.sh, switch
# model in the same session, and prove the task id, session, isolated copy,
# an on-disk edit, and a distinctive conversation detail survive.
#
# Spends a small number of tokens on the cheapest verified subscription
# profiles (zai/glm-5.3 and openai-codex/gpt-5.6-luna). Run with FM_PI_SWITCH_LIVE=1.
# Cleans up the smoke endpoint and worktree.
set -u

# shellcheck source=tests/lib.sh
. "/home/clif/.no-mistakes/worktrees/be2e8740e3ea/01M3PGTVSSDS75000JYAE03R8Y/tests/lib.sh"

fm_live_gate opt-in FM_PI_SWITCH_LIVE pi tmux jq

ROOT="/home/clif/.no-mistakes/worktrees/be2e8740e3ea/01M3PGTVSSDS75000JYAE03R8Y"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-backend.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-pi-switch-lib.sh"

SOURCE_HOME=${FM_HOME:-$ROOT}
REAL_PI=$(command -v pi)
TASK=smoke-pi-switch-$$
LAB=$(mktemp -d "$(cd "${TMPDIR:-/tmp}" && pwd -P)/fm-pi-switch-live.XXXXXX") || fail "could not create lab"
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
  "$ROOT/bin/fm-lab-home.sh" teardown "$LAB" >/dev/null 2>&1 || true
  chmod -R u+w "$LAB" 2>/dev/null || true
  rm -rf "$LAB"

}
trap cleanup EXIT

"$ROOT/bin/fm-lab-home.sh" create "$LAB" >/dev/null
SOCKET_DIR=$("$ROOT/bin/fm-lab-home.sh" tmux-dir "$LAB")
printf 'manual\n' > "$LAB/config/backlog-backend"
printf 'tmux\n' > "$LAB/config/backend"
if [ -f "$SOURCE_HOME/config/pi-account" ]; then
  cp "$SOURCE_HOME/config/pi-account" "$LAB/config/pi-account"
fi
jq -n '{default:[
  {harness:"pi",model:"zai/glm-5.3",effort:"low",provider:"zai"},
  {harness:"pi",model:"zai/glm-5.3",effort:"high",provider:"zai"},
  {harness:"pi",model:"openai-codex/gpt-5.6-luna",effort:"low",provider:"codex"},
  {harness:"pi",model:"nous/openai/gpt-5.5",effort:"low",provider:"nous"},
  {harness:"pi",model:"xai/grok-4.6",effort:"low",provider:"grok"},
  {harness:"cursor",model:"gpt-5.5",effort:"high",provider:"cursor"}
]}' > "$LAB/config/crew-dispatch.json"
mkdir -p "$LAB/fakebin"
cat > "$LAB/fakebin/pi" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in auth|--list-models|--version) exec "$FM_SMOKE_PI" "$@" ;; esac
exec "$FM_SMOKE_PI" --approve --session-dir "$FM_SMOKE_LAB/sessions" -e "$FM_SMOKE_EXT" "$@"
SH
chmod +x "$LAB/fakebin/pi"
export FM_SMOKE_PI="$REAL_PI" FM_SMOKE_EXT="$LAB/recall.ts"
export FM_SMOKE_LAB="$LAB" PATH="$LAB/fakebin:$PATH"
cat > "$LAB/recall.ts" <<'JS'
import { randomBytes } from "node:crypto";
import { existsSync, readFileSync, writeFileSync, unlinkSync } from "node:fs";
export default function (pi) {
  const lab = process.env.FM_SMOKE_LAB;
  const token = randomBytes(16).toString("hex");
  let phase = "initial", timer, response = "";
  pi.on("message_end", (event) => {
    if (event.message.role === "assistant") response = event.message.content.filter(x => x.type === "text").map(x => x.text).join("");
  });
  pi.on("agent_settled", (_event, ctx) => {
    if (!ctx.isIdle()) return;
    if (phase === "initial") {
      phase = "remember";
      pi.setActiveTools([]);
      pi.sendUserMessage("Remember this codeword for a later question: " + token + ". Reply only READY.");
    } else if (phase === "remember") {
      phase = "waiting";
      writeFileSync(lab + "/remembered", ctx.sessionManager.getSessionId());
    } else if (phase.startsWith("recall-")) {
      writeFileSync(lab + "/" + phase, JSON.stringify({ok: response.trim() === token,
        session_id: ctx.sessionManager.getSessionId(), tools: pi.getActiveTools()}));
      phase = "waiting";
    }
  });
  pi.on("session_start", () => {
    timer = setInterval(() => {
      if (phase !== "waiting" || !existsSync(lab + "/recall-request")) return;
      const step = readFileSync(lab + "/recall-request", "utf8").trim();
      unlinkSync(lab + "/recall-request");
      phase = "recall-" + step;
      response = "";
      pi.setActiveTools([]);
      pi.sendUserMessage("What was the earlier codeword? Reply with only that codeword.");
    }, 250);
  });
  pi.on("session_shutdown", () => clearInterval(timer));
}
JS

PROJ="$LAB/projects/smoke"
mkdir -p "$PROJ"
git -C "$PROJ" init -q -b main
git -C "$PROJ" config user.email 'smoke@example.invalid'
git -C "$PROJ" config user.name 'smoke'
printf 'smoke project\n' > "$PROJ/README.md"
printf 'root = "%s"\n' "$LAB" > "$PROJ/treehouse.toml"
git -C "$PROJ" add README.md treehouse.toml
git -C "$PROJ" commit -qm 'fixture: smoke project'

mkdir -p "$LAB/data/$TASK"
cat > "$LAB/data/$TASK/brief.md" <<'EOF'
# Task
## Captain's intent
Live-switch smoke preserving the worker's task, conversation, and edits.
## Firstmate spec
Create SMOKE.txt containing exactly PRESERVED-EDIT and reply READY.
Do not change models or other files.
EOF

export FM_HOME="$LAB" TMUX_TMPDIR="$SOCKET_DIR"
FM_HOME="$LAB" "$ROOT/bin/fm-spawn.sh" "$TASK" "$PROJ" --scout --harness pi \
  --model zai/glm-5.3 --effort low --backend tmux \
  || fail "fm-spawn.sh failed to launch the Pi smoke worker"
SPAWNED=1
WT=$(fm_meta_get "$LAB/state/$TASK.meta" worktree)
case "$WT" in "$LAB"/*) ;; *) fail "spawn worktree escaped the disposable LAB" ;; esac
SESSION_BEFORE=$(fm_meta_get "$LAB/state/$TASK.meta" window)

wait_file() {
  local path=$1
  for _ in $(seq 1 120); do
    [ ! -s "$path" ] || return 0
    sleep 1
  done
  fail "timed out waiting for $path"
}
wait_file "$LAB/remembered"
RUNTIME_SESSION=$(cat "$LAB/remembered")
[ -n "$RUNTIME_SESSION" ] || fail "missing initial runtime session"
ready="$LAB/state/$TASK.model-switch.ready"
[ "$(jq -r .session_id "$ready")" = "$RUNTIME_SESSION" ] || fail "initial session mismatch"
[ "$(jq -r .model "$ready")" = zai/glm-5.3 ] || fail "initial runtime model mismatch"
grep -qx 'PRESERVED-EDIT' "$WT/SMOKE.txt" || fail "initial edit missing"
check_continuity() {
  local step=$1 expected=$2 ack="$LAB/state/$TASK.model-switch.ack"
  jq -e --arg session "$RUNTIME_SESSION" --arg model "$expected" \
    '.session_id == $session and .model == $model and .status == "applied"' "$ack" >/dev/null \
    || fail "switch changed session or did not confirm model"
  printf '%s\n' "$step" > "$LAB/recall-request"
  wait_file "$LAB/recall-$step"
  jq -e --arg session "$RUNTIME_SESSION" '.ok and .session_id == $session and .tools == []' \
    "$LAB/recall-$step" >/dev/null || fail "conversation recall failed with tools disabled"
  [ "$(fm_meta_get "$LAB/state/$TASK.meta" worktree)" = "$WT" ] || fail "worktree changed"
  [ "$(fm_meta_get "$LAB/state/$TASK.meta" endpoint_task_id)" = "$TASK" ] || fail "task identity changed"
  grep -qx 'PRESERVED-EDIT' "$WT/SMOKE.txt" || fail "edit changed"
}

say() { printf '\n### %s\n' "$*"; }
meta="$LAB/state/$TASK.meta"; req="$LAB/state/$TASK.model-switch.req"; HIST="$LAB/state/$TASK.model-switch.log"
sel() { env -u TYPESAFE_API_KEY FM_HOME="$LAB" "$ROOT/bin/fm-profile-switch.sh" --rules "$LAB/config/crew-dispatch.json" --history "$HIST" --rule default --current 'pi:zai/glm-5.3:low:zai' "$@" 2>&1; }
say "real quota-axi bounds for the providers under test"
quota-axi --json | jq -c '.providers[] | select(.provider=="zai" or .provider=="codex" or .provider=="grok" or .provider=="nous" or .provider=="cursor") | {provider, bounds:[.quotaSemantics.effectiveAvailability[]? | {scope,status,effectivePercentRemaining,runway:.runway.status}]}'
say "SELECTOR: quota move to unmeasured nous, unconfirmed"
o=$(sel --checkpoint quota --decision move-provider --selected 'pi:nous/openai/gpt-5.5:low:nous'); echo "$o"
grep -q 'action=hold' <<<"$o" || fail "unconfirmed unmeasured selector must hold"
say "SELECTOR: quota move to unmeasured nous, confirmed"
o=$(sel --checkpoint quota --decision move-provider --selected 'pi:nous/openai/gpt-5.5:low:nous' --confirm-unmeasured-quota); echo "$o"
grep -q 'action=live-switch' <<<"$o" && grep -q 'pass --confirm-unmeasured-quota to switch-model' <<<"$o" || fail "confirmed unmeasured selector must live-switch with note"
say "SELECTOR: native cursor relaunch (unmeasured), unconfirmed then confirmed"
o=$(sel --checkpoint complexity --decision escalate --selected 'cursor:gpt-5.5:high:cursor'); echo "$o"
grep -q 'action=hold' <<<"$o" || fail "unconfirmed native unmeasured must hold"
o=$(sel --checkpoint complexity --decision escalate --selected 'cursor:gpt-5.5:high:cursor' --confirm-unmeasured-quota); echo "$o"
grep -q 'action=relaunch' <<<"$o" || fail "confirmed native unmeasured must relaunch"
say "SELECTOR: exhausted grok with confirmation flag"
o=$(sel --checkpoint quota --decision move-provider --selected 'pi:xai/grok-4.6:low:grok' --confirm-unmeasured-quota); echo "$o"
grep -q 'action=hold' <<<"$o" && grep -q 'failed quota preflight' <<<"$o" || fail "exhausted must hold even when confirmed"
say "SELECTOR: measured codex luna, no flag"
o=$(sel --checkpoint quota --decision move-provider --selected 'pi:openai-codex/gpt-5.6-luna:low:codex'); echo "$o"
grep -q 'action=live-switch' <<<"$o" && ! grep -q unmeasured <<<"$o" || fail "measured must live-switch without confirmation"
say "DIRECT VERB on live worker: unmeasured nous without confirmation"
o=$(FM_HOME="$LAB" "$ROOT/bin/fm-control.sh" "$TASK" switch-model --model nous/openai/gpt-5.5 --effort low 2>&1); rc=$?; echo "$o"; echo "rc=$rc"
[ "$rc" != 0 ] && grep -q 'explicit supervisor confirmation required' <<<"$o" || fail "direct unmeasured must refuse"
[ ! -e "$req" ] || fail "refusal published a request"
echo "meta model after refusal: $(fm_meta_get "$meta" model) effort=$(fm_meta_get "$meta" effort)"
[ "$(fm_meta_get "$meta" model)" = zai/glm-5.3 ] || fail "refusal changed metadata"
say "DIRECT VERB on live worker: exhausted xai WITH confirmation flag"
o=$(FM_HOME="$LAB" "$ROOT/bin/fm-control.sh" "$TASK" switch-model --model xai/grok-4.6 --effort low --confirm-unmeasured-quota 2>&1); rc=$?; echo "$o"; echo "rc=$rc"
[ "$rc" != 0 ] && grep -q 'quota exhausted' <<<"$o" || fail "exhausted must refuse despite confirmation"
[ ! -e "$req" ] || fail "exhausted refusal published a request"
say "DIRECT VERB: flag rejected outside switch-model"
o=$(FM_HOME="$LAB" "$ROOT/bin/fm-control.sh" "$TASK" relaunch --confirm-unmeasured-quota --note x 2>&1); rc=$?; echo "$o"; echo "rc=$rc"
[ "$rc" != 0 ] || fail "flag accepted on relaunch"
echo "tmux pane (worker) before measured switches:"; tmux capture-pane -p -t "$(fm_meta_get "$meta" window)" 2>/dev/null | tail -15 || true
say "MEASURED switches (no flag): same-provider effort high, then cross-provider codex luna"
model_before=$(fm_meta_get "$LAB/state/$TASK.meta" model)
[ "$model_before" = zai/glm-5.3 ] || fail "spawn recorded model=$model_before"

FM_HOME="$LAB" "$ROOT/bin/fm-control.sh" "$TASK" switch-model --effort high \
  || fail "same-provider live switch failed"
model_mid=$(fm_meta_get "$LAB/state/$TASK.meta" model)
effort_mid=$(fm_meta_get "$LAB/state/$TASK.meta" effort)
[ "$model_mid" = zai/glm-5.3 ] || fail "same-provider switch changed model to $model_mid"
[ "$effort_mid" = high ] || fail "same-provider switch recorded effort=$effort_mid instead of the confirmed high"

check_continuity same zai/glm-5.3
FM_HOME="$LAB" "$ROOT/bin/fm-control.sh" "$TASK" switch-model \
  --model openai-codex/gpt-5.6-luna --effort low \
  || fail "cross-provider live switch to openai-codex failed"
model_after=$(fm_meta_get "$LAB/state/$TASK.meta" model)
[ "$model_after" = openai-codex/gpt-5.6-luna ] || fail "cross-provider switch recorded $model_after"
SESSION_AFTER=$(fm_meta_get "$LAB/state/$TASK.meta" window)
[ "$SESSION_BEFORE" = "$SESSION_AFTER" ] || fail "endpoint changed from $SESSION_BEFORE to $SESSION_AFTER"
[ "$(fm_meta_get "$LAB/state/$TASK.meta" dispatch_model)" = zai/glm-5.3 ] \
  || fail "original dispatch snapshot was lost"
check_continuity cross openai-codex/gpt-5.6-luna

say "post-switch metadata and history"
grep -E '^(model|effort|provider|dispatch_model|dispatch_effort|worktree|endpoint_task_id)=' "$meta"
cat "$HIST"
cat "$LAB/recall-same" "$LAB/recall-cross"; echo
say "SELECTOR after real switches: confirmed unmeasured must still hit cooldown"
o=$(sel --checkpoint quota --decision move-provider --selected 'pi:nous/openai/gpt-5.5:low:nous' --confirm-unmeasured-quota); echo "$o"
grep -q cooldown <<<"$o" || fail "confirmation bypassed cooldown"
echo "LAB=$LAB (outside checkout: $(case $LAB in $ROOT/*) echo NO;; *) echo yes;; esac))"
pass "Pi live switches preserved task, runtime session, worktree, edit and tool-free conversation recall"
