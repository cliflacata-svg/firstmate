# Console Quick ask runner verification

Audience: maintainer verification.

This record supports `bin/fm-console-quickask.sh`.
It records the installed-CLI facts that keep the Quick ask lane refuse-closed until a supported subscription runner can enforce the bound.
Task chronology stays in the private task report.
Refresh this page when `codex-cli` or `grok` versions change, or when a new supported switch is claimed.

The bound is: one fresh, non-resumed request; at most 2000 input tokens including runner overhead, of which at most 800 may be a caller-supplied excerpt; at most 512 output tokens; no tool definitions or execution, MCP, apps, hooks, subagents, auto-memory, inherited user or project instructions, session resume, automatic model fallback, or extra summarization calls.

Verified 2026-09-21 on this machine.
`codex-cli 0.154.0` at `/home/clif/.npm-global/bin/codex`.
`grok 1.0.40 (eb1a2256660d) [stable]` at `/home/clif/.local/bin/grok`.
Experiments used an isolated empty git directory inside the task worktree, with no `AGENTS.md`.
No credentials were copied.
No new paid service or API key was used.

## Why Luna does not honour the bound

`codex debug models --bundled` lists `gpt-5.6-luna` with `visibility: list`, `tool_mode: code_mode_only`, `include_plugin_usage_instructions: true`, `include_apps_usage_instructions: true`, `supports_search_tool: true`, and `base_instructions` of 17730 characters.
`truncation_policy` is `{mode: tokens, limit: 10000}`, which is not a 512-output cap.
`codex exec --help` has no max-output or zero-tools switch.
`features.token_budget` is under development and off.
`web_search = "disabled"`, `features.shell_tool=false`, and `--disable` of `apps`, `hooks`, `plugins`, `multi_agent`, `goals`, and `memories` are supported and were used.

`codex debug prompt-input` does not accept `--ignore-user-config`.
With those feature disables and `project_doc_max_bytes=0` in an empty directory, it still emitted 8110 characters of `<skills_instructions>` plus environment context, about 2894 estimated tokens before model base instructions.
With an `AGENTS.md` present it also injected that file.

Live isolated exec, stdin closed:

```sh
codex exec --ephemeral --ignore-user-config --ignore-rules --skip-git-repo-check --json \
  --sandbox read-only -m gpt-5.6-luna \
  --disable shell_tool --disable apps --disable hooks --disable plugins \
  --disable multi_agent --disable goals --disable memories --disable unified_exec \
  --disable browser_use --disable computer_use --disable image_generation --disable skill_search \
  -c 'web_search="disabled"' -c 'agents.enabled=false' -c 'project_doc_max_bytes=0' \
  -c 'model_reasoning_effort="low"' -C <empty-dir> \
  'Reply with the single word PONG. Do not use tools.' < /dev/null
```

Observed JSONL (also `tests/captures/console-quickask/codex-luna-pong.jsonl`):

```json
{"type":"turn.completed","usage":{"input_tokens":6147,"cached_input_tokens":0,"cache_write_input_tokens":0,"output_tokens":6,"reasoning_output_tokens":0}}
```

One turn, no tool-execution items, 6147 input tokens for a one-word answer.
That already exceeds 2000.
JSONL does not list tool definitions, so absence of `command_execution` items is not proof that none were offered.
Output happened to be 6 tokens; nothing enforced 512.

## Why Grok does not honour the bound

Installed `grok --help` lists `--single`/`-p`, `--max-turns`, `--tools`, `--disallowed-tools`, `--disable-web-search`, `--no-plan`, `--no-subagents`, `--verbatim`, and `--system-prompt-override`.
It does not list `--no-memory`.
`grok --no-memory --version` exits 0, while `grok --definitely-not-a-real-flag --version` exits 2, so the flag is accepted and is not a no-op parse.
Current documentation lists `--no-memory`; the help gap is why this page verifies the installed binary.

`grok inspect --json` from the isolated empty directory still loaded 5 user hooks (`~/.claude` and `~/.grok/hooks`), 36 skills (14 user, 22 bundled), 3 builtin agents, and `~/.grok/config.toml`.
`GROK_MEMORY=0 GROK_SUBAGENTS=0` did not change that inspect result.
MCP servers and plugins were empty in this inspect snapshot.
`--tools` still keeps always-on MCP meta-tools per the installed headless guide.
`[models].max_completion_tokens` exists in user config (default 8192) and is not proven here as a 512 generation cap.
`--max-turns` counts agent turns, not tokens.

Live isolated probe:

```sh
GROK_MEMORY=0 GROK_SUBAGENTS=0 GROK_WEB_FETCH=0 \
GROK_CONFIG='{"models":{"max_completion_tokens":512,"default_reasoning_effort":"low"}}' \
grok --cwd <empty-dir> --no-memory --no-subagents --no-plan --disable-web-search \
  --verbatim --no-leader --no-auto-update --max-turns 1 --effort low \
  --sandbox read-only --permission-mode dontAsk \
  --disallowed-tools 'run_terminal_cmd,read_file,grep,list_dir,search_replace,web_search,web_fetch,Agent' \
  --system-prompt-override 'Answer with one word only. Do not use tools.' \
  --output-format streaming-json \
  -p 'Reply with the single word PONG.'
```

Observed spend fields (compacted capture: `tests/captures/console-quickask/grok-verbatim-pong.jsonl`):

```json
{"type":"end","stopReason":"end_turn","usage":{"input_tokens":12957,"cache_read_input_tokens":128,"output_tokens":33,"reasoning_tokens":31,"total_tokens":13118},"num_turns":1,"modelUsage":{"grok-4.6-build":{"modelCalls":1}}}
```

The same stream advertised a non-empty `tools` array on `available_commands` (todo_write, monitor, search_tool, use_tool, workflow, image_gen, write, and others) and listed inherited user skill commands.
One model call, no tool_call events on this prompt, 12957 uncached input tokens.
That already exceeds 2000.
Tool definitions were present, so a later question could execute them.
`--verbatim` and `--system-prompt-override` did not remove that overhead.

## What this does not prove

A timeout is not a token cap.
An output display limit is not a generation cap.
`--max-turns 1` proved one recorded turn on these two probes; it did not cap tokens.
Claude was not probed: the VPS host facts said it is unauthenticated there, and this task did not log in.

Until a later capture shows a supported runner under every clause of the bound, `fm-console-quickask.sh ask` must refuse rather than invoke a model.
`fm-console-quickask.sh inspect-events` is the command that re-evaluates a recorded JSONL against the same caps.
It fails closed: a clause the events cannot show is a violation (`requests_unobservable`, `tool_definitions_unobservable`), so a Codex JSONL, which lists neither tool definitions nor a model-call count, cannot report `honours`.
