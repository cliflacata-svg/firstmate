#!/usr/bin/env bash
# fm-console-quickask.sh - bounded one-shot ask adapter for the console Quick
# ask lane.
#
# The intended contract is one fresh, non-resumed request carrying a brief
# fixed instruction, the current question, and a caller-supplied memory excerpt:
# at most 2000 input tokens including runner overhead (at most 800 of those for
# the excerpt) and at most 512 output tokens, with no tool definitions, no tool
# execution, no MCP or apps, no hooks, no subagents, no auto-memory, no
# inherited user or project instructions, no session resume, no automatic model
# fallback, and no extra summarization or title-generation calls.
#
# Prefer Codex GPT-5.6 Luna through the existing ChatGPT Plus/Codex
# subscription if a supported runner can enforce that bound. On the installed
# CLIs verified 2026-09-21 (codex-cli 0.154.0 and grok 1.0.40), neither can:
# an isolated one-word Luna exec used 6147 input tokens, and an isolated Grok
# --verbatim --no-memory probe used 12957 input tokens while still advertising
# tool definitions and inherited skills. No supported switch caps output at 512
# tokens. This script therefore refuses to invoke a model rather than shipping
# a full agent under a cheap label.
#
# Evidence: docs/verification/console-quickask.md
# This is not fm-inbox.sh ask (Bedrock/AWS). Do not route Quick ask there.
#
# Usage:
#   fm-console-quickask.sh ask --question <text> [--excerpt <text>]
#   fm-console-quickask.sh ask --question <text> [--excerpt-file <path>]
#   fm-console-quickask.sh inspect-events --kind codex|grok <jsonl>
#   fm-console-quickask.sh --help
#
# ask assembles the prompt, estimates caller-supplied tokens with
# ceil(UTF-8 bytes / 3) from bin/fm-startup-memory-budget-lib.sh, and refuses
# without a provider call when the excerpt, the assembled prompt, or the
# installed runner cannot honour the bound.
#
# inspect-events reads a runner's own structured JSONL and reports whether
# those recorded events honour the bound. It is the test and evidence path
# for a real provider transcript; it never starts a model.
#
# Output: key=value lines on stdout. Human detail on stderr for refusals.
#
# Exit status:
#   0  inspect-events: recorded events honour the bound
#   1  ask refused, or inspect-events found a bound violation
#   2  usage error
set -euo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-startup-memory-budget-lib.sh
. "$SELF_DIR/fm-startup-memory-budget-lib.sh"

MAX_INPUT_TOKENS=2000
MAX_EXCERPT_TOKENS=800
MAX_OUTPUT_TOKENS=512
FIXED_INSTRUCTION='Answer the question using only the supplied excerpt. If the excerpt is insufficient, say so. Do not use tools. Do not call tools, browse, or spawn helpers.'

usage() {
  cat <<'EOF'
fm-console-quickask.sh - bounded one-shot ask adapter for the console Quick ask lane.

Usage:
  fm-console-quickask.sh ask --question <text> [--excerpt <text>]
  fm-console-quickask.sh ask --question <text> [--excerpt-file <path>]
  fm-console-quickask.sh inspect-events --kind codex|grok <jsonl>
  fm-console-quickask.sh --help

The lane stays refuse-closed on the verified CLIs. See the script header and
docs/verification/console-quickask.md.
EOF
}

die_usage() {
  printf 'error: %s\n' "$1" >&2
  usage >&2
  exit 2
}

utf8_bytes() {
  printf '%s' "$1" | wc -c
}

estimate_tokens() {
  local bytes=$1 tokens
  bytes=$((bytes))
  tokens=$(fm_startup_memory_estimated_tokens_for_bytes "$bytes") || return 1
  printf '%s\n' "$tokens"
}

print_kv() {
  printf '%s=%s\n' "$1" "$2"
}

emit_ask_refusal() {
  local reason=$1 question_tokens=$2 excerpt_tokens=$3 assembled_tokens=$4
  print_kv status refused
  print_kv reason "$reason"
  print_kv question_tokens "$question_tokens"
  print_kv excerpt_tokens "$excerpt_tokens"
  print_kv assembled_tokens "$assembled_tokens"
  print_kv max_input_tokens "$MAX_INPUT_TOKENS"
  print_kv max_excerpt_tokens "$MAX_EXCERPT_TOKENS"
  print_kv max_output_tokens "$MAX_OUTPUT_TOKENS"
  print_kv usage none
  print_kv runner none
  print_kv model none
}

cmd_ask() {
  local question="" excerpt="" excerpt_file="" have_excerpt=0 have_file=0
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --question)
        [ "$#" -ge 2 ] || die_usage "ask --question needs a value"
        question=$2
        shift 2
        ;;
      --excerpt)
        [ "$#" -ge 2 ] || die_usage "ask --excerpt needs a value"
        excerpt=$2
        have_excerpt=1
        shift 2
        ;;
      --excerpt-file)
        [ "$#" -ge 2 ] || die_usage "ask --excerpt-file needs a path"
        excerpt_file=$2
        have_file=1
        shift 2
        ;;
      --help|-h)
        usage
        exit 0
        ;;
      --)
        shift
        break
        ;;
      -*)
        die_usage "unknown ask flag: $1"
        ;;
      *)
        die_usage "unexpected ask argument: $1"
        ;;
    esac
  done
  [ -n "$question" ] || die_usage "ask requires --question"
  if [ "$have_excerpt" -eq 1 ] && [ "$have_file" -eq 1 ]; then
    die_usage "pass only one of --excerpt or --excerpt-file"
  fi
  if [ "$have_file" -eq 1 ]; then
    if [ -z "$excerpt_file" ] || [ -L "$excerpt_file" ] || [ ! -f "$excerpt_file" ]; then
      printf 'error: excerpt file must be an ordinary non-symlink file\n' >&2
      exit 2
    fi
    excerpt=$(cat -- "$excerpt_file")
  fi

  local assembled excerpt_display q_bytes e_bytes a_bytes q_tokens e_tokens a_tokens
  excerpt_display=$excerpt
  if [ -z "$excerpt_display" ]; then
    excerpt_display='(none)'
  fi
  assembled=$(printf 'INSTRUCTION\n%s\n\nEXCERPT\n%s\n\nQUESTION\n%s\n' \
    "$FIXED_INSTRUCTION" "$excerpt_display" "$question")
  q_bytes=$(utf8_bytes "$question")
  e_bytes=$(utf8_bytes "$excerpt")
  a_bytes=$(utf8_bytes "$assembled")
  q_tokens=$(estimate_tokens "$q_bytes")
  e_tokens=$(estimate_tokens "$e_bytes")
  a_tokens=$(estimate_tokens "$a_bytes")

  if [ "$e_tokens" -gt "$MAX_EXCERPT_TOKENS" ]; then
    emit_ask_refusal excerpt-over-budget "$q_tokens" "$e_tokens" "$a_tokens"
    printf 'error: memory excerpt is %s estimated tokens; cap is %s. Refusing rather than sending a growing transcript.\n' \
      "$e_tokens" "$MAX_EXCERPT_TOKENS" >&2
    exit 1
  fi
  if [ "$a_tokens" -gt "$MAX_INPUT_TOKENS" ]; then
    emit_ask_refusal assembled-over-budget "$q_tokens" "$e_tokens" "$a_tokens"
    printf 'error: assembled prompt is %s estimated tokens; cap is %s including runner overhead. Refusing rather than growing the request.\n' \
      "$a_tokens" "$MAX_INPUT_TOKENS" >&2
    exit 1
  fi

  emit_ask_refusal runner-unenforced "$q_tokens" "$e_tokens" "$a_tokens"
  cat >&2 <<'EOF'
error: Quick ask is unavailable: no installed subscription runner can enforce the bounded contract.
codex-cli 0.154.0 gpt-5.6-luna: isolated one-word exec used 6147 input tokens (cap 2000); no max-output switch exists; debug prompt-input still injects skills and project instructions; Luna base_instructions are 17730 characters.
grok 1.0.40: isolated --verbatim --no-memory --no-subagents --system-prompt-override one-word probe used 12957 input tokens, advertised tool definitions, and inherited user skills; --no-memory is accepted but absent from --help; no proven 512-output cap.
A timeout or --max-turns flag is not a token cap. Display truncation is not a generation cap. Refusing rather than invoking a full agent.
See docs/verification/console-quickask.md
EOF
  exit 1
}

cmd_inspect_events() {
  local kind="" path=""
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --kind)
        [ "$#" -ge 2 ] || die_usage "inspect-events --kind needs codex or grok"
        kind=$2
        shift 2
        ;;
      --help|-h)
        usage
        exit 0
        ;;
      --)
        shift
        break
        ;;
      -*)
        die_usage "unknown inspect-events flag: $1"
        ;;
      *)
        path=$1
        shift
        break
        ;;
    esac
  done
  [ -n "$kind" ] || die_usage "inspect-events requires --kind codex|grok"
  case "$kind" in
    codex|grok) ;;
    *) die_usage "inspect-events --kind must be codex or grok" ;;
  esac
  [ -n "$path" ] || die_usage "inspect-events requires a JSONL file"
  if [ -L "$path" ] || [ ! -f "$path" ]; then
    printf 'error: events file must be an ordinary non-symlink file\n' >&2
    exit 2
  fi

  KIND=$kind MAX_INPUT_TOKENS=$MAX_INPUT_TOKENS MAX_OUTPUT_TOKENS=$MAX_OUTPUT_TOKENS \
    python3 - "$path" <<'PY'
import json, os, sys

path = sys.argv[1]
kind = os.environ["KIND"]
max_in = int(os.environ["MAX_INPUT_TOKENS"])
max_out = int(os.environ["MAX_OUTPUT_TOKENS"])

events = []
with open(path, encoding="utf-8") as fh:
    for line in fh:
        line = line.strip()
        if not line:
            continue
        events.append(json.loads(line))

input_tokens = 0
output_tokens = 0
reasoning_tokens = 0
turns = 0
model_calls = 0
tool_definitions = 0
tool_executions = 0
def as_int(value):
    if isinstance(value, bool) or value is None:
        return 0
    if isinstance(value, (int, float)):
        return int(value)
    return 0

def take_usage(usage):
    global input_tokens, output_tokens, reasoning_tokens
    if not isinstance(usage, dict):
        return
    input_tokens = max(
        input_tokens,
        as_int(usage.get("input_tokens")) + as_int(usage.get("cache_read_input_tokens")),
        as_int(usage.get("input_tokens")) + as_int(usage.get("cached_input_tokens")),
    )
    output_tokens = max(output_tokens, as_int(usage.get("output_tokens")))
    reasoning_tokens = max(
        reasoning_tokens,
        as_int(usage.get("reasoning_tokens")),
        as_int(usage.get("reasoning_output_tokens")),
    )

for ev in events:
    if not isinstance(ev, dict):
        continue
    et = ev.get("type")
    if et in ("turn.completed", "usage", "end"):
        take_usage(ev.get("usage"))
        turns = max(turns, as_int(ev.get("num_turns")))
        model_usage = ev.get("modelUsage")
        if isinstance(model_usage, dict):
            for row in model_usage.values():
                if isinstance(row, dict):
                    model_calls = max(model_calls, as_int(row.get("modelCalls")))
    if et == "turn.started":
        turns += 1
    if et == "available_commands":
        tools = ev.get("tools")
        if isinstance(tools, list) and tools:
            tool_definitions = max(tool_definitions, len(tools))
    if et in ("tool_call", "tool_call_update"):
        tool_executions += 1
    item = ev.get("item")
    if isinstance(item, dict):
        itype = item.get("type")
        if itype in ("command_execution", "mcp_tool_call", "web_search", "file_change"):
            tool_executions += 1

if kind == "codex" and turns == 0:
    turns = sum(1 for ev in events if isinstance(ev, dict) and ev.get("type") == "turn.started")

combined_out = output_tokens + reasoning_tokens
violations = []
if input_tokens > max_in:
    violations.append("input_tokens")
if combined_out > max_out:
    violations.append("output_tokens")
if turns > 1 or model_calls > 1:
    violations.append("multiple_requests")
if tool_definitions > 0:
    violations.append("tool_definitions")
if tool_executions > 0:
    violations.append("tool_execution")
if input_tokens == 0 and output_tokens == 0:
    violations.append("usage_unreported")

status = "honours" if not violations else "violates"
print(f"status={status}")
print(f"kind={kind}")
print(f"input_tokens={input_tokens}")
print(f"output_tokens={output_tokens}")
print(f"reasoning_tokens={reasoning_tokens}")
print(f"turns={turns}")
print(f"model_calls={model_calls}")
print(f"tool_definitions={tool_definitions}")
print(f"tool_executions={tool_executions}")
print(f"violations={','.join(violations) if violations else 'none'}")
print(f"max_input_tokens={max_in}")
print(f"max_output_tokens={max_out}")
if status == "honours":
    sys.exit(0)
sys.exit(1)
PY
}

main() {
  if [ "$#" -eq 0 ]; then
    die_usage "missing command"
  fi
  case "$1" in
    --help|-h)
      usage
      exit 0
      ;;
    ask)
      shift
      cmd_ask "$@"
      ;;
    inspect-events)
      shift
      cmd_inspect_events "$@"
      ;;
    *)
      die_usage "unknown command: $1"
      ;;
  esac
}

main "$@"
