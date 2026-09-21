#!/usr/bin/env bash
set -u
BIN=/home/clif/.no-mistakes/worktrees/be2e8740e3ea/01M3160NPCGZS4B894JST8VVTQ/bin
H=$(mktemp -d /tmp/fm-console-live2.XXXXXX); mkdir -p $H/state $H/data $H/config
export FM_HOME=$H FM_STATE_OVERRIDE=$H/state FM_DATA_OVERRIDE=$H/data FM_CONFIG_OVERRIDE=$H/config
nid(){ "$BIN/fm-inbox.sh" note --request-id "$1" --json "$2" | python3 -c 'import json,sys;print(json.load(sys.stdin)["id"])'; }
echo "== reply cursor: client reads only what is new =="
A=$(nid a "order A"); B=$(nid b "order B"); C=$(nid c "order C")
"$BIN/fm-inbox.sh" reply "$A" "answer A" >/dev/null; "$BIN/fm-inbox.sh" reply "$B" "answer B" >/dev/null
CUR=$("$BIN/fm-inbox.sh" receipts | python3 -c 'import json,sys;print(json.load(sys.stdin)["reply_cursor"])')
echo "client cursor after first poll: $CUR"
"$BIN/fm-inbox.sh" reply "$C" "answer C" >/dev/null
echo "\$ fm-inbox.sh receipts --after $CUR  (replies[] only)"
"$BIN/fm-inbox.sh" receipts --after "$CUR" | python3 -c 'import json,sys;d=json.load(sys.stdin);print(json.dumps({"replies":d["replies"],"reply_cursor":d["reply_cursor"]},indent=1))'
echo "--- simulate lost .seq counter, then a new reply"
rm -f $H/state/inbox/.replies/.seq; D=$(nid d "order D"); "$BIN/fm-inbox.sh" reply "$D" "answer D" >/dev/null
CUR2=$("$BIN/fm-inbox.sh" receipts --after "$CUR" | python3 -c 'import json,sys;print(json.load(sys.stdin)["reply_cursor"])')
"$BIN/fm-inbox.sh" receipts --after 000000000003 | python3 -c 'import json,sys;d=json.load(sys.stdin);print("after 3 ->",[(r["id"],r["body"],r["cursor"]) for r in d["replies"]])'
echo; echo "== ready: live harness holder + fresh beacon, then away =="
perl -e '$0="claude"; sleep 30' & HP=$!; sleep 0.3
printf '%s\n' $HP > $H/state/.lock; touch $H/state/.last-watcher-beat
echo "\$ fm-inbox.sh ready"; "$BIN/fm-inbox.sh" ready; echo
echo "\$ fm-lock.sh status"; "$BIN/fm-lock.sh" status
echo away > $H/state/.afk
echo "\$ fm-inbox.sh ready  (after .afk=away)"; "$BIN/fm-inbox.sh" ready; echo
touch -d '2 hours ago' $H/state/.last-watcher-beat
echo "\$ fm-inbox.sh ready  (beacon 2h old)"; "$BIN/fm-inbox.sh" ready; echo
kill $HP; wait $HP 2>/dev/null
echo "\$ fm-inbox.sh ready  (holder exited)"; "$BIN/fm-inbox.sh" ready; echo
ls $H/state/.lock >/dev/null && echo "lock file untouched by ready: $(cat $H/state/.lock)"
rm -rf "$H"
