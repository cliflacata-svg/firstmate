# Console Quick ask runner captures

These files own recorded structured output from the installed subscription CLIs for `tests/fm-console-quickask.test.sh`.
They are replay inputs for `bin/fm-console-quickask.sh inspect-events`, not proof that a later CLI version still matches.

Audience for the live guarantee is [`docs/verification/console-quickask.md`](../../../docs/verification/console-quickask.md).

## Capture provenance

Captured 2026-09-21 on this machine, inside an isolated empty git directory with no `AGENTS.md`.
No credentials were copied.

| File | Runner | What it is |
| --- | --- | --- |
| `codex-luna-pong.jsonl` | `codex-cli 0.154.0` `codex exec --json -m gpt-5.6-luna` with `--ephemeral --ignore-user-config` and feature disables, stdin closed | Unchanged stdout of the isolated one-word probe |
| `grok-verbatim-pong.jsonl` | `grok 1.0.40` `-p` with `--verbatim --no-memory --no-subagents --system-prompt-override --max-turns 1` | Compacted stdout: one `available_commands` line, the `usage` line, and the `end` line. The usage `signature` field is replaced with `redacted`. Thought/text deltas are omitted because they are not load-bearing for the bound |
| `synthetic-honours.jsonl` | none | Counterfactual Grok-shaped empty `available_commands` tool list and `end` record under the caps, so `inspect-events` can return success. Not a captured live run |
| `synthetic-truncated.jsonl` | none | Counterfactual Grok-shaped truncated run: empty `available_commands` tool list and a `usage` line under the caps, but no `end` record, so `inspect-events` must report the single request as unobservable. Not a captured live run |

Update the verification record when refreshing these captures.
