#!/usr/bin/env bash
# Manual live drive: busy deferral, cross-provider zai->openai-codex Luna, conversation memory.
set -u
ROOT=$PWD
. "$ROOT/bin/fm-backend.sh"; . "$ROOT/bin/fm-pi-switch-lib.sh"
TASK=manual-pi-switch-$$
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX")
"$ROOT/bin/fm-lab-home.sh" create "$LAB" >/dev/null
SOCKET_DIR=$("$ROOT/bin/fm-lab-home.sh" tmux-dir "$LAB")
printf 'manual\n' > "$LAB/config/backlog-backend"; printf 'tmux\n' > "$LAB/config/backend"
export FM_HOME="$LAB" TMUX_TMPDIR="$SOCKET_DIR"
WT=
cleanup(){ "$ROOT/bin/fm-control.sh" "$TASK" exit >/dev/null 2>&1; tmux kill-server >/dev/null 2>&1
  [ -n "$WT" ] && [ -d "$WT" ] && { treehouse return "$WT" >/dev/null 2>&1; rm -rf "$WT"; }
  chmod -R u+w "$LAB"; rm -rf "$LAB"; }
trap cleanup EXIT
PROJ="$LAB/projects/smoke"; mkdir -p "$PROJ"; git -C "$PROJ" init -q -b main
git -C "$PROJ" -c user.email=s@e.invalid -c user.name=s commit -q --allow-empty -m init
mkdir -p "$LAB/data/$TASK"; STATUS="$LAB/state/$TASK.status"
CODE="MARMALADE-$RANDOM-OTTER"
cat > "$LAB/data/$TASK/brief.md" <<EOF
# Task
## Captain's intent
Remember this secret phrase in your memory only; never write it to any file until asked: $CODE
Append \`working [at=<epoch>]: ready\` to $STATUS and wait for further instructions.
## Firstmate spec
Do not change models yourself. Do not modify the repository.
EOF
"$ROOT/bin/fm-spawn.sh" "$TASK" "$PROJ" --scout --harness pi --model zai/glm-5.3 --effort medium --backend tmux || { echo "SPAWN FAIL"; exit 1; }
META="$LAB/state/$TASK.meta"; WT=$(fm_meta_get "$META" worktree); EP=$(fm_meta_get "$META" window)
for _ in $(seq 90); do grep -q ': ready' "$STATUS" 2>/dev/null && break; sleep 2; done
echo "--- status after spawn"; cat "$STATUS"
grep -rl "$CODE" "$WT" 2>/dev/null && echo "WARN codeword on disk" || echo "codeword not on disk (conversation-only)"
echo "--- meta before"; grep -E '^(model|effort|account_provider|dispatch_model|dispatch_effort)=' "$META"
echo "--- pane footer before"; tmux capture-pane -p -t "$EP" | grep -v '^\s*$' | tail -4
echo "=== BUSY DEFERRAL: start a long turn then switch with short idle wait"
"$ROOT/bin/fm-send.sh" "$TASK" "Run the shell command 'sleep 45' now, then append \`working [at=<epoch>]: slept\` to $STATUS." >/dev/null
sleep 6
FM_CONTROL_SWITCH_IDLE_WAIT=5 "$ROOT/bin/fm-control.sh" "$TASK" switch-model --model openai-codex/gpt-5.6-luna --effort low; echo "busy switch rc=$?"
echo "--- meta after busy attempt"; grep -E '^(model|effort)=' "$META"
for _ in $(seq 60); do grep -q ': slept' "$STATUS" && break; sleep 2; done; sleep 3
echo "=== CROSS-PROVIDER to Luna at idle"
"$ROOT/bin/fm-control.sh" "$TASK" switch-model --model openai-codex/gpt-5.6-luna --effort low; echo "switch rc=$?"
echo "--- meta after"; grep -E '^(model|effort|account_provider|dispatch_model|dispatch_effort)=' "$META"
echo "--- endpoint before=$EP after=$(fm_meta_get "$META" window)"
echo "--- pane footer after"; tmux capture-pane -p -t "$EP" | grep -v '^\s*$' | tail -4
echo "=== RECALL from conversation memory"
"$ROOT/bin/fm-send.sh" "$TASK" "Without reading any file, append \`working [at=<epoch>]: recall <the secret phrase from your brief>\` to $STATUS." >/dev/null
for _ in $(seq 90); do grep -q ': recall' "$STATUS" && break; sleep 2; done
echo "--- status"; cat "$STATUS"
grep -q "recall $CODE" "$STATUS" && echo "RECALL OK: $CODE" || echo "RECALL FAIL"
echo "--- switch log"; cat "$(fm_pi_switch_log_path "$LAB/state" "$TASK")"
echo "--- ack"; cat "$(fm_pi_switch_ack_path "$LAB/state" "$TASK")"; echo
echo "=== UNSUPPORTED MODEL refused, runtime+meta unchanged"
"$ROOT/bin/fm-control.sh" "$TASK" switch-model --model openai-codex/gpt-9-imaginary --effort low; echo "bogus switch rc=$?"
grep -E '^(model|effort|account_provider)=' "$META"
echo "=== UNSUPPORTED EFFORT refused"
"$ROOT/bin/fm-control.sh" "$TASK" switch-model --model zai/glm-5.3 --effort ludicrous; echo "bad effort rc=$?"
echo "=== CROSS-PROVIDER to grok subscription (xai) in pi rotation"
"$ROOT/bin/fm-control.sh" "$TASK" switch-model --model xai/grok-4.5 --effort low; echo "grok switch rc=$?"
grep -E '^(model|effort|account_provider)=' "$META"
echo "--- pane footer"; tmux capture-pane -p -t "$EP" | grep -v '^\s*$' | tail -2
echo "--- switch log"; cat "$(fm_pi_switch_log_path "$LAB/state" "$TASK")"
