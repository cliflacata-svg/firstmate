#!/usr/bin/env bash
# Live driver: real tmux server on a lab-private socket, real fm-control.sh /
# fm-spawn.sh against a marked disposable lab FM_HOME. Usage: <bin-root> <label>
set -u
BINROOT=$1; LABEL=$2
REPO=$(pwd)
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX"); rmdir "$LAB"
"$REPO/bin/fm-lab-home.sh" create "$LAB" >/dev/null
mkdir -p "$LAB/tmux" "$LAB/other-tmux" "$LAB/user-home"
T="env TMUX_TMPDIR=$LAB/tmux tmux"
cleanup() { $T kill-server 2>/dev/null; rm -rf "$LAB"; }
trap cleanup EXIT
# project + worktree for the ship task
git init -q "$LAB/proj"; git -C "$LAB/proj" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
git -C "$LAB/proj" worktree add -q -b task-lv1 "$LAB/wt"
echo "never committed" > "$LAB/wt/dirty.txt"
mkdir -p "$LAB/data/lv1"
printf '# Task\n## Captain'"'"'s intent\nLab reclaim fixture.\n\n## Firstmate spec\nIdle; do nothing.\n' > "$LAB/data/lv1/brief.md"
cat > "$LAB/state/lv1.meta" <<EOF
window=fmlab:fm-lv1
endpoint_task_id=lv1
worktree=$LAB/wt
project=$LAB/proj
harness=claude
kind=ship
mode=no-mistakes
yolo=off
tasktmp=/tmp/fm-lv1-lab
model=default
effort=default
EOF
run() {  # <tmux-tmpdir> <cmd...>
  local td=$1; shift
  env -u TMUX -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE \
      -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE \
      -u HERDR_ENV -u HERDR_PANE_ID -u HERDR_SESSION -u HERDR_SOCKET_PATH -u HERDR_TAB_ID -u HERDR_WORKSPACE_ID \
      TMUX_TMPDIR="$td" FM_HOME="$LAB" HOME="$LAB/user-home" CLAUDE_CONFIG_DIR="$LAB/user-home/.claude" \
      FM_SPAWN_NO_GUARD=1 FM_CONTROL_EXIT_WAIT=2 FM_CONTROL_LAUNCH_WAIT=5 "$@" 2>&1
}
step() { echo; echo "\$ $*"; }
echo "=== [$LABEL] bin=$BINROOT  tmux=$(tmux -V)"
# The recorded session exists on this seat's server, but the task window is gone.
$T new-session -d -s fmlab -n keeper -c "$LAB"
$T new-window -d -t fmlab: -n fm-lv1 -c "$LAB/wt"
$T kill-window -t fmlab:fm-lv1
step "tmux list-windows -t =fmlab   # recorded window fm-lv1 destroyed"; $T list-windows -t =fmlab -F '#{window_name}'

echo; echo "---- S3 adversarial: seat on a DIFFERENT tmux server (other TMUX_TMPDIR, no server there)"
step "fm-control.sh lv1 exit"; run "$LAB/other-tmux" "$BINROOT/bin/fm-control.sh" lv1 exit; echo "rc=$?"
step "fm-spawn.sh lv1 --relaunch --harness claude"; run "$LAB/other-tmux" "$BINROOT/bin/fm-spawn.sh" lv1 --relaunch --harness claude; echo "rc=$?"
step "other server sessions (must be none):"; TMUX_TMPDIR="$LAB/other-tmux" tmux ls 2>&1

echo; echo "---- S3b adversarial: recorded session renamed away on this seat's server (can't find session)"
$T rename-session -t fmlab fmlab-renamed
step "fm-spawn.sh lv1 --relaunch --harness claude"; run "$LAB/tmux" "$BINROOT/bin/fm-spawn.sh" lv1 --relaunch --harness claude; echo "rc=$?"
step "fm-control.sh lv1 exit"; run "$LAB/tmux" "$BINROOT/bin/fm-control.sh" lv1 exit; echo "rc=$?"
step "sessions/windows after refusal:"; $T list-windows -a -F '#{session_name}:#{window_name}'
$T rename-session -t fmlab-renamed fmlab

echo; echo "---- S1: exit on a window omitted from the recorded session's inventory"
step "fm-control.sh lv1 exit"; run "$LAB/tmux" "$BINROOT/bin/fm-control.sh" lv1 exit; echo "rc=$?"
step "grep window= state/lv1.meta"; grep '^window=' "$LAB/state/lv1.meta"

echo; echo "---- S2: --relaunch reclaims into the recorded session with a real claude"
HEAD_BEFORE=$(git -C "$LAB/wt" rev-parse HEAD)
step "fm-spawn.sh lv1 --relaunch --harness claude"; run "$LAB/tmux" "$BINROOT/bin/fm-spawn.sh" lv1 --relaunch --harness claude; echo "rc=$?"
step "tmux list-windows -a (after)"; $T list-windows -a -F '#{session_name}:#{window_name} #{window_id} cmd=#{pane_current_command} cwd=#{pane_current_path}'
step "grep window= state/lv1.meta"; grep -E '^(window|harness|worktree)=' "$LAB/state/lv1.meta"
step "worktree HEAD unchanged / dirty file kept"; [ "$(git -C "$LAB/wt" rev-parse HEAD)" = "$HEAD_BEFORE" ] && echo "HEAD unchanged"; cat "$LAB/wt/dirty.txt"
sleep 6
step "capture-pane fmlab:fm-lv1"; $T capture-pane -p -t fmlab:fm-lv1 2>&1 | sed '/^$/d' | tail -25

echo; echo "---- S4 adversarial: the reclaimed endpoint now holds a live agent -> relaunch refuses"
step "tmux pane command"; $T display-message -p -t fmlab:fm-lv1 '#{pane_current_command}'
step "fm-spawn.sh lv1 --relaunch --harness claude"; run "$LAB/tmux" "$BINROOT/bin/fm-spawn.sh" lv1 --relaunch --harness claude; echo "rc=$?"
step "window count for fm-lv1 (must be 1)"; $T list-windows -a -F '#{window_name}' | grep -cx fm-lv1
echo "=== [$LABEL] done; tearing down lab"
