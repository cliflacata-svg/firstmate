#!/usr/bin/env bash
# Behavior tests for bin/fm-console-quickask.sh: the console Quick ask adapter.
#
# The adapter must refuse when the bound cannot be honoured, and it must
# assemble a bounded prompt so a caller cannot send a growing transcript.
# Real provider calls stay out of this suite; inspect-events is asserted
# against recorded runner JSONL under tests/captures/console-quickask/.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SCRIPT="$ROOT/bin/fm-console-quickask.sh"
CAPTURES="$ROOT/tests/captures/console-quickask"
TMP_ROOT=$(fm_test_tmproot fm-console-quickask)

# --- help and usage ---------------------------------------------------------

help_out=$("$SCRIPT" --help) || fail " --help should exit 0"
assert_contains "$help_out" 'fm-console-quickask.sh ask --question' \
  "--help names the ask contract"
assert_contains "$help_out" 'inspect-events' \
  "--help names inspect-events"
pass "help prints the ask and inspect-events contracts"

code=0
"$SCRIPT" >"$TMP_ROOT/empty.out" 2>"$TMP_ROOT/empty.err" || code=$?
expect_code 2 "$code" "missing command"
pass "missing command is a usage error"

code=0
"$SCRIPT" ask >"$TMP_ROOT/noq.out" 2>"$TMP_ROOT/noq.err" || code=$?
expect_code 2 "$code" "ask without --question"
pass "ask without --question is a usage error"

code=0
"$SCRIPT" ask --question 'one' --excerpt 'a' --excerpt-file /dev/null \
  >"$TMP_ROOT/both.out" 2>"$TMP_ROOT/both.err" || code=$?
expect_code 2 "$code" "both excerpt flags"
pass "ask rejects both --excerpt and --excerpt-file"

# --- runner cannot honour: small question still refuses, no model argv ------

FAKEBIN=$(fm_fakebin "$TMP_ROOT/fakebin")
cat > "$FAKEBIN/codex" <<'SH'
#!/usr/bin/env bash
printf 'codex-cli must-not-run\n' >&2
exit 97
SH
cat > "$FAKEBIN/grok" <<'SH'
#!/usr/bin/env bash
printf 'grok must-not-run\n' >&2
exit 97
SH
chmod +x "$FAKEBIN/codex" "$FAKEBIN/grok"

code=0
out=$(PATH="$FAKEBIN:$PATH" "$SCRIPT" ask --question 'What is 2+2?' --excerpt 'two plus two is four.' \
  2>"$TMP_ROOT/ask-small.err") || code=$?
expect_code 1 "$code" "small ask"
assert_contains "$out" 'status=refused' "small ask is refused"
assert_contains "$out" 'reason=runner-unenforced' "small ask names runner-unenforced"
assert_contains "$out" 'usage=none' "small ask reports no usage"
assert_contains "$out" 'runner=none' "small ask does not pick a runner"
assert_contains "$out" 'max_input_tokens=2000' "small ask prints the input cap"
assert_contains "$out" 'max_excerpt_tokens=800' "small ask prints the excerpt cap"
assert_contains "$out" 'max_output_tokens=512' "small ask prints the output cap"
err=$(cat "$TMP_ROOT/ask-small.err")
assert_contains "$err" '6147' "refusal names the Luna input-token evidence"
assert_contains "$err" '12957' "refusal names the Grok input-token evidence"
assert_not_contains "$err" 'must-not-run' "ask must not invoke codex or grok"
pass "small question refuses as runner-unenforced without invoking a CLI"

# --- bounded assembly: growing excerpt is refused as excerpt-over-budget ----

# 800 tokens at ceil(bytes/3) is 2400 bytes; 2401 bytes is 801 tokens.
long_excerpt=$(python3 -c 'print("m"*2401)')
code=0
out=$(PATH="$FAKEBIN:$PATH" "$SCRIPT" ask --question 'summarise that' --excerpt "$long_excerpt" \
  2>"$TMP_ROOT/ask-long.err") || code=$?
expect_code 1 "$code" "long excerpt ask"
assert_contains "$out" 'reason=excerpt-over-budget' "long excerpt is excerpt-over-budget"
assert_contains "$out" 'excerpt_tokens=801' "long excerpt is 801 estimated tokens"
assert_not_contains "$out" 'reason=runner-unenforced' \
  "excerpt over budget is reported before the runner gap"
assert_not_contains "$(cat "$TMP_ROOT/ask-long.err")" 'must-not-run' \
  "over-budget excerpt must not invoke a CLI"
pass "an 801-token excerpt is refused as excerpt-over-budget"

# Same bound through --excerpt-file, so a dumped transcript file cannot sneak in.
printf '%s' "$long_excerpt" > "$TMP_ROOT/transcript.txt"
code=0
out=$(PATH="$FAKEBIN:$PATH" "$SCRIPT" ask --question 'summarise that' \
  --excerpt-file "$TMP_ROOT/transcript.txt" \
  2>"$TMP_ROOT/ask-file.err") || code=$?
expect_code 1 "$code" "excerpt-file ask"
assert_contains "$out" 'reason=excerpt-over-budget' "excerpt-file uses the same cap"
pass "--excerpt-file of a growing transcript is refused as excerpt-over-budget"

code=0
"$SCRIPT" ask --question 'x' --excerpt-file "$TMP_ROOT/missing.txt" \
  >"$TMP_ROOT/ask-missing.out" 2>"$TMP_ROOT/ask-missing.err" || code=$?
expect_code 2 "$code" "missing excerpt file"
pass "missing excerpt file is a usage error"

ln -s "$TMP_ROOT/transcript.txt" "$TMP_ROOT/transcript.link"
code=0
"$SCRIPT" ask --question 'x' --excerpt-file "$TMP_ROOT/transcript.link" \
  >"$TMP_ROOT/ask-link.out" 2>"$TMP_ROOT/ask-link.err" || code=$?
expect_code 2 "$code" "symlink excerpt file"
pass "symlink excerpt file is refused"

# Caller-assembled prompt over 2000 estimated tokens, with excerpt still <= 800.
# Instruction + labels + 799-token excerpt + a large question.
big_question=$(python3 -c 'print("q"*6000)')
medium_excerpt=$(python3 -c 'print("e"*2397)')
code=0
out=$(PATH="$FAKEBIN:$PATH" "$SCRIPT" ask --question "$big_question" --excerpt "$medium_excerpt" \
  2>"$TMP_ROOT/ask-assembled.err") || code=$?
expect_code 1 "$code" "assembled-over-budget ask"
assert_contains "$out" 'reason=assembled-over-budget' "huge question hits assembled-over-budget"
pass "assembled prompt over 2000 estimated tokens is refused"

# --- inspect-events against recorded runner output -------------------------

code=0
out=$("$SCRIPT" inspect-events --kind codex "$CAPTURES/codex-luna-pong.jsonl" \
  2>"$TMP_ROOT/inspect-codex.err") || code=$?
expect_code 1 "$code" "codex capture"
assert_contains "$out" 'status=violates' "codex capture violates"
assert_contains "$out" 'input_tokens=6147' "codex capture reports 6147 input tokens"
assert_contains "$out" 'violations=input_tokens' "codex capture violation is input_tokens"
assert_contains "$out" 'tool_executions=0' "codex capture had no tool-execution items"
pass "recorded Luna JSONL is reported as input-over-budget"

code=0
out=$("$SCRIPT" inspect-events --kind grok "$CAPTURES/grok-verbatim-pong.jsonl" \
  2>"$TMP_ROOT/inspect-grok.err") || code=$?
expect_code 1 "$code" "grok capture"
assert_contains "$out" 'status=violates' "grok capture violates"
assert_contains "$out" 'input_tokens=13085' "grok capture counts uncached plus cache-read input"
assert_contains "$out" 'tool_definitions=14' "grok capture saw advertised tools"
assert_contains "$out" 'violations=input_tokens,tool_definitions' \
  "grok capture names input and tool-definition violations"
pass "recorded Grok JSONL is reported as input-over-budget with tool definitions"

code=0
out=$("$SCRIPT" inspect-events --kind grok "$CAPTURES/synthetic-honours.jsonl" \
  2>"$TMP_ROOT/inspect-ok.err") || code=$?
expect_code 0 "$code" "synthetic honours"
assert_contains "$out" 'status=honours' "synthetic record can honour"
assert_contains "$out" 'violations=none' "synthetic record has no violations"
pass "inspect-events can return honours on a record under the caps"

code=0
"$SCRIPT" inspect-events --kind grok "$TMP_ROOT/transcript.link" \
  >"$TMP_ROOT/inspect-link.out" 2>"$TMP_ROOT/inspect-link.err" || code=$?
expect_code 2 "$code" "symlink events file"
pass "inspect-events refuses a symlink events file"
