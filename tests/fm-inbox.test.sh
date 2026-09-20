#!/usr/bin/env bash
# tests/fm-inbox.test.sh - captain inbox capture, receipts, replies, readiness.
#
# Covers the durable order contract: request-id idempotency, the crash window
# between save and announce, saved-but-unannounced repair, bounded receipts
# JSON with omission disclosure, the reply cursor, and the readiness
# projection's unknown path. Human note/list/drain behaviour stays unchanged
# when the new flags are omitted.
set -euo pipefail

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-inbox)
INBOX_BIN="$ROOT/bin/fm-inbox.sh"
LOCK_BIN="$ROOT/bin/fm-lock.sh"

make_home() {
  local home="$TMP_ROOT/$1"
  mkdir -p "$home/state" "$home/data" "$home/config"
  printf '%s\n' "$home"
}

run_inbox() {
  local home=$1
  shift
  FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_CONFIG_OVERRIDE="$home/config" "$INBOX_BIN" "$@"
}

run_lock() {
  local home=$1
  shift
  FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" "$LOCK_BIN" "$@"
}

json_get() {
  python3 -c 'import json,sys
v=json.load(sys.stdin)
for k in sys.argv[1:]:
    if isinstance(v, list) and k.lstrip("-").isdigit():
        v=v[int(k)]
    else:
        v=v[k]
print(v)' "$@"
}

count_notes() {
  find "$1/state/inbox" -maxdepth 1 -name '*.note' 2>/dev/null | wc -l | tr -d ' '
}

count_wakes() {
  if [ -f "$1/state/.wake-queue" ]; then
    grep -c 'inbox:' "$1/state/.wake-queue" || true
  else
    printf '0\n'
  fi
}

# --- human note path is unchanged without the new flags ---------------------

home=$(make_home human)
out=$(run_inbox "$home" note "hello from the terminal") \
  || fail "plain note should succeed"
assert_contains "$out" "queued " "plain note should print queued <id>"
assert_contains "$out" "firstmate will pick this up at its next check." \
  "plain note should keep its human announcement line"
assert_equals "1" "$(count_notes "$home")" "plain note should write one record"
assert_equals "1" "$(count_wakes "$home")" "plain note should append one wake"
list_out=$(run_inbox "$home" list) || fail "list should succeed"
assert_contains "$list_out" "hello from the terminal" "list should show the body"
pass "plain note, list, and wake stay on the historical human path"

# A saved note whose wake fails still exits 1 for callers that omit the new flags.
isolated="$TMP_ROOT/isolated"
mkdir -p "$isolated/bin"
cp "$INBOX_BIN" "$isolated/bin/fm-inbox.sh"
chmod +x "$isolated/bin/fm-inbox.sh"
home=$(make_home human-wake-fail)
set +e
fail_out=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
  "$isolated/bin/fm-inbox.sh" note "saved but not announced" 2>&1)
fail_code=$?
set -e
expect_code 1 "$fail_code" "plain note still exits 1 when announcement fails"
assert_equals "1" "$(count_notes "$home")" \
  "plain note is saved even when announcement fails"
assert_contains "$fail_out" "queued " "plain note still prints queued before the failure"
assert_contains "$fail_out" "NOT woken" "plain note still reports the wake failure"
pass "plain note keeps exit 1 for a saved-but-unannounced failure"

# --- duplicate request id returns the original identity ---------------------

home=$(make_home idempotent)
body=$'line one\nline two\n'
first=$(printf '%s' "$body" | run_inbox "$home" note --request-id req-1 --json -) \
  || fail "first request-id note should succeed"
first_id=$(printf '%s' "$first" | json_get id)
assert_equals "created" "$(printf '%s' "$first" | json_get outcome)" \
  "first submission is created"
assert_equals "True" "$(printf '%s' "$first" | json_get saved)" \
  "first submission is saved"
assert_equals "True" "$(printf '%s' "$first" | json_get announced)" \
  "first submission is announced"
assert_equals "req-1" "$(printf '%s' "$first" | json_get request_id)" \
  "receipt carries the request id"

second=$(printf '%s' "$body" | run_inbox "$home" note --request-id req-1 --json -) \
  || fail "replay of the same request id should succeed"
assert_equals "replay" "$(printf '%s' "$second" | json_get outcome)" \
  "repeat request id is a replay, not a second create"
assert_equals "$first_id" "$(printf '%s' "$second" | json_get id)" \
  "replay returns the original note id"
assert_equals "1" "$(count_notes "$home")" \
  "the same request id must not create a second note"
assert_equals "1" "$(count_wakes "$home")" \
  "replay of an already-announced note must not append a second wake"
replay_human=$(run_inbox "$home" note --request-id req-1 "line one") \
  || fail "human replay should succeed"
assert_contains "$replay_human" "replay $first_id" \
  "human replay is distinguishable from queued"
assert_equals "1" "$(count_notes "$home")" "human replay still does not duplicate"
pass "the same request id returns the original note as a distinguishable replay"

# --- crash window: reservation exists, note not yet published ---------------

home=$(make_home crash-reserve)
mkdir -p "$home/state/inbox/.requests"
crash_id="1700000000-crashwin"
printf '%s\n' "$crash_id" > "$home/state/inbox/.requests/crash-rid"
assert_absent "$home/state/inbox/$crash_id.note" \
  "fixture starts with a reservation and no published note"
crash_out=$(run_inbox "$home" note --request-id crash-rid --json "recover me") \
  || fail "retry after a reservation-only crash should complete the original note"
assert_equals "replay" "$(printf '%s' "$crash_out" | json_get outcome)" \
  "completing a reserved request id is a replay of that request"
assert_equals "$crash_id" "$(printf '%s' "$crash_out" | json_get id)" \
  "the reserved note id is reused"
assert_present "$home/state/inbox/$crash_id.note" \
  "the retry publishes the reserved note rather than minting a new id"
assert_equals "1" "$(count_notes "$home")" \
  "crash-window retry leaves exactly one note"
assert_grep "recover me" "$home/state/inbox/$crash_id.note" \
  "the completed note carries the caller's body"
pass "a crash between recording the request id and publishing the note reuses the original id"

# --- saved-but-unannounced, then repair without a second note ---------------

home=$(make_home announce-fail)
set +e
saved_out=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
  "$isolated/bin/fm-inbox.sh" note --request-id repair-1 --json "please announce" 2>/dev/null)
saved_code=$?
set -e
expect_code 3 "$saved_code" "request-id note exits 3 when saved but not announced"
assert_equals "created" "$(printf '%s' "$saved_out" | json_get outcome)" \
  "first isolated submit is created"
assert_equals "True" "$(printf '%s' "$saved_out" | json_get saved)" \
  "isolated submit saved the note"
assert_equals "False" "$(printf '%s' "$saved_out" | json_get announced)" \
  "isolated submit could not announce"
saved_id=$(printf '%s' "$saved_out" | json_get id)
assert_equals "1" "$(count_notes "$home")" "isolated submit wrote one note"
assert_equals "0" "$(count_wakes "$home")" "isolated submit wrote no wake"

set +e
replay_fail=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
  "$isolated/bin/fm-inbox.sh" note --request-id repair-1 --json "please announce" 2>/dev/null)
replay_fail_code=$?
set -e
expect_code 3 "$replay_fail_code" "replay while still unannounced also exits 3"
assert_equals "replay" "$(printf '%s' "$replay_fail" | json_get outcome)" \
  "retry with the same request id is a replay"
assert_equals "$saved_id" "$(printf '%s' "$replay_fail" | json_get id)" \
  "unannounced retry keeps the original id"
assert_equals "1" "$(count_notes "$home")" \
  "unannounced retry must not create a second note"

repair=$(run_inbox "$home" note --request-id repair-1 --json "please announce") \
  || fail "replay with a working announcer should repair the wake"
assert_equals "replay" "$(printf '%s' "$repair" | json_get outcome)" \
  "repair is still a replay"
assert_equals "True" "$(printf '%s' "$repair" | json_get announced)" \
  "repair announces the existing note"
assert_equals "$saved_id" "$(printf '%s' "$repair" | json_get id)" \
  "repair keeps the original id"
assert_equals "1" "$(count_notes "$home")" "repair does not create a second note"
assert_equals "1" "$(count_wakes "$home")" "repair appends exactly one wake"

already=$(run_inbox "$home" announce --json "$saved_id") \
  || fail "announce of an already-announced note should succeed"
assert_equals "replay" "$(printf '%s' "$already" | json_get outcome)" \
  "second announce is already-announced"
assert_equals "1" "$(count_wakes "$home")" \
  "already-announced must not append another wake"
pass "saved-but-unannounced notes are repairable without creating a second note"

# --- bounded receipts JSON, omission disclosure, reply cursor ---------------

home=$(make_home receipts)
i=0
while [ "$i" -lt 3 ]; do
  run_inbox "$home" note --request-id "pending-$i" "pending body $i" >/dev/null
  i=$((i + 1))
done
i=0
while [ "$i" -lt 5 ]; do
  hid_json=$(run_inbox "$home" note --request-id "handled-$i" --json "handled body $i") \
    || fail "handled fixture note $i failed"
  hid=$(printf '%s' "$hid_json" | json_get id)
  run_inbox "$home" drain --ack "$hid" >/dev/null
  i=$((i + 1))
done

receipts=$(FM_INBOX_RECEIPTS_PENDING=2 FM_INBOX_RECEIPTS_HANDLED=2 \
  FM_INBOX_RECEIPTS_REPLIES=2 run_inbox "$home" receipts) \
  || fail "receipts should succeed"
assert_equals "fm-inbox-receipts.v1" "$(printf '%s' "$receipts" | json_get schema)" \
  "receipts use the receipts schema"
pending_len=$(printf '%s' "$receipts" | python3 -c 'import json,sys; print(len(json.load(sys.stdin)["pending"]))')
handled_len=$(printf '%s' "$receipts" | python3 -c 'import json,sys; print(len(json.load(sys.stdin)["handled"]))')
assert_equals "2" "$pending_len" "pending list is bounded"
assert_equals "2" "$handled_len" "handled list is bounded"
assert_contains "$receipts" "pending notes omitted by bound:" \
  "receipts disclose omitted pending notes"
assert_contains "$receipts" "handled notes omitted by bound:" \
  "receipts disclose omitted handled notes"
assert_contains "$receipts" "raise FM_INBOX_RECEIPTS_PENDING or pass --all-pending" \
  "omission names how to reveal pending notes"
assert_contains "$receipts" '"acknowledged":false' "pending notes are not acknowledged"
assert_contains "$receipts" '"acknowledged":true' "handled notes are acknowledged"

all_receipts=$(run_inbox "$home" receipts --all-pending --all-handled) \
  || fail "unbounded receipts should succeed"
all_pending=$(printf '%s' "$all_receipts" | python3 -c 'import json,sys; print(len(json.load(sys.stdin)["pending"]))')
all_handled=$(printf '%s' "$all_receipts" | python3 -c 'import json,sys; print(len(json.load(sys.stdin)["handled"]))')
assert_equals "3" "$all_pending" "--all-pending reveals every pending note"
assert_equals "5" "$all_handled" "--all-handled reveals every handled note"
assert_equals "[]" "$(printf '%s' "$all_receipts" | python3 -c 'import json,sys; print(json.load(sys.stdin)["omitted"])')" \
  "revealing every row leaves omitted empty"
pass "receipts JSON is bounded and discloses what it omitted"

# Reply cursor: two replies, --after the first in sort order returns the rest.
home=$(make_home cursor)
id1=$(run_inbox "$home" note --request-id c1 --json "first order" | json_get id)
id2=$(run_inbox "$home" note --request-id c2 --json "second order" | json_get id)
run_inbox "$home" reply "$id1" "answer one" >/dev/null
run_inbox "$home" reply "$id2" "answer two" >/dev/null
replies=$(run_inbox "$home" receipts --all-replies) || fail "receipts with replies should succeed"
reply_count=$(printf '%s' "$replies" | python3 -c 'import json,sys; print(len(json.load(sys.stdin)["replies"]))')
assert_equals "2" "$reply_count" "both replies appear without a cursor"
first_cursor=$(printf '%s' "$replies" | python3 -c 'import json,sys
r=json.load(sys.stdin)["replies"][0]
print("%s|%s" % (r.get("at") or "", r.get("id") or ""))')
first_reply_id=$(printf '%s' "$replies" | python3 -c 'import json,sys; print(json.load(sys.stdin)["replies"][0]["id"])')
after=$(run_inbox "$home" receipts --all-replies --after "$first_cursor") \
  || fail "receipts --after should succeed"
after_count=$(printf '%s' "$after" | python3 -c 'import json,sys; print(len(json.load(sys.stdin)["replies"]))')
assert_equals "1" "$after_count" "--after returns only later replies in cursor order"
after_id=$(printf '%s' "$after" | python3 -c 'import json,sys; print(json.load(sys.stdin)["replies"][0]["id"])')
assert_not_equals "$first_reply_id" "$after_id" \
  "the reply after the cursor is the other note, not the one already seen"
replay_reply=$(run_inbox "$home" reply --json "$id1" "answer one") \
  || fail "identical reply is a replay"
assert_equals "replay" "$(printf '%s' "$replay_reply" | json_get outcome)" \
  "an identical reply is distinguishable as replay"
set +e
conflict=$(run_inbox "$home" reply "$id1" "a different answer" 2>&1)
conflict_code=$?
set -e
expect_code 1 "$conflict_code" "a conflicting second reply is refused"
assert_contains "$conflict" "already recorded" "conflicting reply names the existing record"
pass "the reply channel is durable, cursor-readable, and idempotent on the same body"

# --- readiness projection, including unknown -------------------------------

home=$(make_home ready-free)
ready=$(run_inbox "$home" ready) || fail "ready should succeed with no lock"
assert_equals "fm-primary-ready.v1" "$(printf '%s' "$ready" | json_get schema)" \
  "ready uses the readiness schema"
assert_equals "free" "$(printf '%s' "$ready" | python3 -c 'import json,sys; print(json.load(sys.stdin)["lock"]["state"])')" \
  "no lock file is free, not live"
assert_equals "False" "$(printf '%s' "$ready" | python3 -c 'import json,sys; print(json.load(sys.stdin)["can_receive"])')" \
  "a free lock cannot receive work"
assert_equals "present" "$(printf '%s' "$ready" | python3 -c 'import json,sys; print(json.load(sys.stdin)["posture"]["state"])')" \
  "no away flag is present posture"

# A live non-harness pid in the lock file must not be treated as a live primary.
home=$(make_home ready-unknown)
printf '%s\n' "$$" > "$home/state/.lock"
ready=$(run_inbox "$home" ready) || fail "ready should succeed for an unclassified pid"
lock_state=$(printf '%s' "$ready" | python3 -c 'import json,sys; print(json.load(sys.stdin)["lock"]["state"])')
assert_equals "unknown" "$lock_state" \
  "a live process that is not a verified harness is unknown, not held"
live=$(printf '%s' "$ready" | python3 -c 'import json,sys; print(json.load(sys.stdin)["lock"]["live_harness"])')
assert_equals "False" "$live" "a bash test pid is not a live harness"
can=$(printf '%s' "$ready" | python3 -c 'import json,sys; print(json.load(sys.stdin)["can_receive"])')
[ "$can" = "False" ] || [ "$can" = "unknown" ] \
  || fail "unknown lock must not claim can_receive true (got $can)"

lock_json=$(run_lock "$home" status --json) || fail "lock status --json should succeed"
assert_equals "unknown" "$(printf '%s' "$lock_json" | json_get state)" \
  "lock status --json reports unknown for a live non-harness pid"
human_lock=$(run_lock "$home" status) || fail "lock status should succeed"
assert_contains "$human_lock" "stale (pid $$ dead or not a harness)" \
  "human lock status keeps its historical stale wording"

# Dead pid is stale, not held.
home=$(make_home ready-stale)
printf '%s\n' "999999" > "$home/state/.lock"
ready=$(run_inbox "$home" ready) || fail "ready should succeed for a dead pid"
assert_equals "stale" "$(printf '%s' "$ready" | python3 -c 'import json,sys; print(json.load(sys.stdin)["lock"]["state"])')" \
  "a dead recorded pid is stale"
assert_equals "False" "$(printf '%s' "$ready" | python3 -c 'import json,sys; print(json.load(sys.stdin)["can_receive"])')" \
  "a stale lock cannot receive work"

# Existence of a pane-like leftover must not become liveness: unreadable lock.
home=$(make_home ready-unreadable)
mkdir -p "$home/state/.lock"
ready=$(run_inbox "$home" ready) || fail "ready should succeed for a directory lock"
assert_equals "unreadable" "$(printf '%s' "$ready" | python3 -c 'import json,sys; print(json.load(sys.stdin)["lock"]["state"])')" \
  "a non-file lock is unreadable rather than held"
pass "readiness says unknown (or not-receivable) instead of inferring liveness from a lock"

# --- invalid input ----------------------------------------------------------

home=$(make_home invalid)
set +e
empty_out=$(run_inbox "$home" note --request-id x --json "   " 2>&1)
empty_code=$?
bad_out=$(run_inbox "$home" note --request-id '../etc/passwd' --json "nope" 2>&1)
bad_code=$?
set -e
expect_code 1 "$empty_code" "empty body is still refused"
expect_code 1 "$bad_code" "path-like request ids are refused"
assert_contains "$empty_out" "empty" "empty-body refusal says the note was empty"
assert_contains "$bad_out" "invalid request id" "unsafe request ids are rejected by name"
assert_equals "0" "$(count_notes "$home")" "refusals must not write a note"
pass "empty bodies and unsafe request ids are refused"

# --- drain still acks by moving the note ------------------------------------

home=$(make_home drain)
queued=$(run_inbox "$home" note "ack me") || fail "note for drain failed"
did=${queued#queued }
did=${did%%$'\n'*}
run_inbox "$home" drain --ack "$did" >/dev/null || fail "drain --ack failed"
assert_absent "$home/state/inbox/$did.note" "acked note leaves pending"
assert_present "$home/state/inbox/handled/$did.note" "acked note is in handled"
pass "drain --ack still moves the note to handled"
