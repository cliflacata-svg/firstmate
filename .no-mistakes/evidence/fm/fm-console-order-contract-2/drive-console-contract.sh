#!/usr/bin/env bash
# Live CLI drive of the console order contract in a throwaway FM_HOME.
set -u
BIN=/home/clif/.no-mistakes/worktrees/be2e8740e3ea/01M3160NPCGZS4B894JST8VVTQ/bin
H=$(mktemp -d /tmp/fm-console-live.XXXXXX); mkdir -p $H/state $H/data $H/config
export FM_HOME=$H FM_STATE_OVERRIDE=$H/state FM_DATA_OVERRIDE=$H/data FM_CONFIG_OVERRIDE=$H/config
inbox(){ echo "\$ fm-inbox.sh $*"; "$BIN/fm-inbox.sh" "$@"; echo "[exit $?]"; }
wakes(){ echo "wake rows: $(grep -c 'inbox:' $H/state/.wake-queue 2>/dev/null || echo 0)  notes pending: $(ls $H/state/inbox/*.note 2>/dev/null | wc -l)  handled: $(ls $H/state/inbox/handled/*.note 2>/dev/null | wc -l)"; }
echo "== S1 idempotent retry of a multiline order =="
printf 'deploy the console\nsecond line\n' | inbox note --request-id web-req-1 --json -
printf 'deploy the console\nsecond line\n' | inbox note --request-id web-req-1 --json -
wakes
echo; echo "== S2 saved but wake failed -> exit 3, repair without second note =="
touch $H/state/.wake-queue; chmod 444 $H/state/.wake-queue
inbox note --request-id web-req-2 --json "fix the flaky test"
ID2=$(ls -t $H/state/inbox/*.note | head -1 | xargs basename | sed 's/\.note$//')
inbox note --request-id web-req-2 --json "fix the flaky test"
wakes
chmod 644 $H/state/.wake-queue
inbox announce --json "$ID2"
inbox announce --json "$ID2"
inbox note --request-id web-req-2 --json "fix the flaky test"
wakes
echo; echo "== S3 acked note gets no repair wake =="
chmod 444 $H/state/.wake-queue
inbox note --request-id web-req-3 --json "acked before repair"
ID3=$(ls -t $H/state/inbox/*.note | head -1 | xargs basename | sed 's/\.note$//')
chmod 644 $H/state/.wake-queue
inbox drain --ack "$ID3"
inbox announce --json "$ID3"
inbox note --request-id web-req-3 --json "acked before repair"
wakes
echo; echo "== S4 primary replies; receipts cursor =="
ID1=$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["id"])' <(printf 'x\n' | "$BIN/fm-inbox.sh" note --request-id web-req-1 --json - 2>/dev/null))
inbox drain --ack "$ID1"
inbox reply --json "$ID1" "Console deploy started; PR to follow."
inbox reply --json "$ID1" "second answer"
inbox receipts > $H/r1.json; echo "[receipts exit $?]"; python3 -m json.tool $H/r1.json
CUR=$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1])).get("cursor") or json.load(open(sys.argv[1]))["replies"]["cursor"])' $H/r1.json 2>/dev/null)
echo "cursor=$CUR"
inbox reply --json "$ID2" "Flaky test fixed."
echo "\$ fm-inbox.sh receipts --after <cursor>"; "$BIN/fm-inbox.sh" receipts --after "$CUR" | python3 -m json.tool
echo; echo "== S5 bounded receipts with omission disclosure =="
for i in $(seq 1 25); do "$BIN/fm-inbox.sh" note --request-id bulk-$i --json "bulk $i" >/dev/null; done
"$BIN/fm-inbox.sh" receipts | python3 -c 'import json,sys;d=json.load(sys.stdin);print("pending shown:",len(d["pending"]),"omitted:",json.dumps(d.get("omitted")))'
"$BIN/fm-inbox.sh" receipts --all-pending | python3 -c 'import json,sys;d=json.load(sys.stdin);print("--all-pending shown:",len(d["pending"]),"omitted:",json.dumps(d.get("omitted")))'
echo; echo "== S6 readiness projection =="
inbox ready
printf '%s\n' $$ > $H/state/.lock; touch $H/state/.last-watcher-beat
inbox ready
printf '999999\n' > $H/state/.lock
inbox ready
echo "\$ fm-lock.sh status"; "$BIN/fm-lock.sh" status; echo "[exit $?]"
touch $H/state/away 2>/dev/null
echo; echo "== S7 adversarial: bad ids, empty body, body that looks like flags =="
inbox note --request-id '../escape' --json "x"
inbox note --request-id ok-1 --json ""
inbox note --request-id dash-1 --json -- --all-pending
inbox announce --json 'no-such-note'
inbox reply --json 'no-such-note' "x"
echo; echo "== S8 plain human note path unchanged =="
inbox note "plain human note"
inbox list | tail -3
rm -rf "$H"
