#!/usr/bin/env bash
# Manual live drive: busy deferral, cross-provider zai->openai-codex Luna, conversation memory.
set -u
ROOT=$PWD
. "$ROOT/bin/fm-backend.sh"; . "$ROOT/bin/fm-pi-switch-lib.sh"
TASK=relaunch-pi-switch-$$
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
cat > "$LAB/data/$TASK/brief.md" <<EOB
# Task
## Captain's intent
Append \`working [at=<epoch>]: ready\` to $STATUS and wait for further instructions.
## Firstmate spec
Do not change models yourself. Do not modify the repository.
EOB
"$ROOT/bin/fm-spawn.sh" "$TASK" "$PROJ" --scout --harness pi --model zai/glm-5.3 --effort low --backend tmux || { echo "SPAWN FAIL"; exit 1; }
META="$LAB/state/$TASK.meta"; WT=$(fm_meta_get "$META" worktree); EP=$(fm_meta_get "$META" window)
for _ in $(seq 90); do grep -q ': ready' "$STATUS" 2>/dev/null && break; sleep 2; done; sleep 3
echo "=== switch zai -> xai/grok-4.5 low"
"$ROOT/bin/fm-control.sh" "$TASK" switch-model --model xai/grok-4.5 --effort low; echo "switch rc=$?"
grep -E '^(model|effort|account_provider|dispatch_model|dispatch_effort)=' "$META"
echo "=== relaunch (no flags) must come back on last confirmed profile"
"$ROOT/bin/fm-control.sh" "$TASK" relaunch --note "Relaunch test: continue waiting for instructions."; echo "relaunch rc=$?"
EP=$(fm_meta_get "$META" window)
for _ in $(seq 45); do tmux capture-pane -p -t "$EP" 2>/dev/null | grep -q 'grok-4.5\|glm-5.3' && break; sleep 2; done; sleep 4
echo "--- meta after relaunch"; grep -E '^(model|effort|account_provider|dispatch_model|dispatch_effort)=' "$META"
echo "--- pane footer after relaunch"; tmux capture-pane -p -t "$EP" | grep -v '^\s*$' | tail -2
