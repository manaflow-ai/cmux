# Tool evals

Does a model use cmux's tools correctly? Each case is one user turn that once went
wrong (or a control that must keep working). The runner replays it on a real model
with the prompt a real harness sends, and grades what the model did. The model of
this eval is t3code's `evals/mcp-tool-use`; the cmux side here is real, not simulated.

- The prompt: a trimmed Claude Code capture (`templates/claude.json.gz`) supplies the
  system prompt, native tools and environment message. The cmux text in it (MCP
  instructions, tool names and descriptions) comes from the `cmux` binary under test,
  never from a copy, so a run always tests the current text.
- cmux: every sample gets an ephemeral headless daemon (`session.mjs`) and
  `cmux mcp serve` on it. `cmux_exec` scripts, MCP tool calls and `cmux ...` shell
  commands run for real. A stand-in app socket answers only `system.identify` (the
  agent's terminal) and `snapshot.get` (focus), so `current` and `focused` resolve as
  in the app; other app actions fail. A case with `"noApp": true` runs with no app.
- Shell: the agent's Bash runs in a scratch directory under `sandbox-exec` (no writes
  under `/Users`, no cmux socket but the sample's own).
- Grading: `expect.state` uses the agent-evals checks (placement, focus, grouping;
  `../agent-evals/grade.mjs`) on before and after snapshots; `calls`, `callsMustNot`,
  `maxCalls`, `maxErrors`, `maxSteps`, `order`, `shellMustNot`, `textMust`,
  `textMustNot` grade the calls and the reply (`grade.mjs`). A case fails when half or
  more of its samples fail.
- The headless agent-evals tasks run here too, as `ae-*` guard cases.

## Surfaces

| `--surface` | What the agent gets |
| --- | --- |
| `code` | `cmux mcp serve`: one tool, `cmux_exec`, behind Claude Code's tool search |
| `all` | `cmux mcp serve --all-tools`: every tool, behind tool search |
| `cli` | no MCP; `cmux` on PATH |

## Run

The model route is `ANTHROPIC_BASE_URL` / `ANTHROPIC_AUTH_TOKEN` (the sr2 gateway in a
cmux chat). Models: `claude-sonnet-5-5` (default), `claude-opus-5-5`, `claude-haiku-5-5`.

```sh
bun tests/tool-evals/run.mjs --case terminal-right --samples 1 --out /tmp/te/check
bun tests/tool-evals/run.mjs --surface code,all,cli --samples 2 --out /tmp/te/sonnet
bun tests/tool-evals/run.mjs --model claude-opus-5-5 --baseline /tmp/te/sonnet/results.jsonl --out /tmp/te/opus
bun tests/tool-evals/run.mjs --context --out /tmp/te/ctx   # sizes of the cmux text, no model
```

Flags: `--case <ids>`, `--cases <files>`, `--samples <n>` (default 2),
`--concurrency <n>` (default 4), `--max-steps <n>` (20), `--effort <level>`,
`--cli <cmux binary>` (default: cmux NIGHTLY's), `--baseline <results.jsonl>`.

### Prompt-guidance A/B

Use the same fixed cases, model, surface, samples and catalog for both arms. The
`--prompt-arm baseline` arm leaves the current cmux instructions unchanged. The
`--prompt-arm guidance` arm replaces the trailing duplicated asking rule in the
synthetic MCP instructions with the compact rule and appends the canonical
early/concurrent-work guidance. Real CLI runs append guidance through the Claude
preset or Codex developer instruction field. Those runs leave the MCP rule from the
selected product binary unchanged. Use the same binary in both arms. These system/
developer-field experiments do not reproduce the product's first-turn user-context
delivery; use the standalone paired evaluator below for that intervention.
The allowed values are `none`, `baseline`, and `guidance`; `none` is the default
and leaves the prompt untouched. The standalone candidate is a combined compact-
asking-plus-concurrency intervention, so its paired result cannot attribute a
difference to either text independently.

```sh
bun tests/tool-evals/run.mjs --model claude-sonnet-5-5 --surface code \
  --cases tests/tool-evals/cases/discovery.ndjson --samples 5 --prompt-arm baseline \
  --out artifacts/tool-evals/guidance-baseline
bun tests/tool-evals/run.mjs --model claude-sonnet-5-5 --surface code \
  --cases tests/tool-evals/cases/discovery.ndjson --samples 5 --prompt-arm guidance \
  --out artifacts/tool-evals/guidance-candidate
```

Each row records `tool_calls`, `tool_turns`, `parallel_tool_turns`,
`parallel_share`, `first_read_ms`, success, wall seconds and input/output/cache
tokens. A tool turn is one model response containing one or more calls; a parallel
turn has at least two calls in that response. Codex app-server groups overlapping
`item/started` tool events into the same turn. Report paired medians and success;
do not infer a speedup from a single arm or from historical runs.

For early reads and background work without an app build, run the standalone
captured-Claude harness against fixed synthetic repository fixtures:

```sh
cmux-ci test --setup none --timeout 1800 --artifact /tmp/prompt-behavior -- \
  node tests/tool-evals/prompt-behavior.mjs --samples 3
```

Set `ANTHROPIC_BASE_URL` to the gateway reachable by the selected worker and set
`ANTHROPIC_AUTH_TOKEN` in its environment when required. The evaluator reads both
variables; it does not accept credentials or gateway URLs on the command line.

It alternates arm order for each paired task/sample. It uses the captured Claude
Code 2.1.311 system prompt and native Read/Bash schemas captured on 2026-10-27.
The baseline asking rule is frozen at its recorded source revision, so a later
product change cannot silently alter the control. Both arms approximate MCP server
instructions with a labelled system block: the old rule in baseline, the compact
rule in candidate. Only candidate appends the exact `<cmux-default-context>`
concurrency guidance as the last block of the first user prompt, matching product
delivery. The product seam is implemented by
[cmux#34702](https://github.com/manaflow-ai/cmux/pull/34702). A guard rejects
captures that already include these cmux additions.
This is not live MCP initialization or a complete current harness context.
The three tasks cover independent config reads, cross-file contract comparison,
and a test command with independent release-note reads. The contract task passes
only when the answer connects the server's `retries` field to the schema's
`retry_limit`, rather than merely mentioning the word "server". Results are deterministic
fixtures with a 250ms read and 2s command delay; no generated shell runs. A task
passes only when the model reads every named file, collects its test output, and
reports the required facts. `manifest.json` records the prompts, hashes and estimate
method, source channels and delivery limitation; `results.jsonl`, per-sample
transcripts and `summary.json` record measured
model usage and behavior. Report this as a synthetic prompt-behavior eval, not as
live app or Codex verification. The model endpoint must be reachable from the worker.

`--overlay <file.json>` swaps text without a rebuild, for hill-climbing copy:
`{ "instructions": "...", "exec": "...", "tools": { "pane_split": "..." } }`. It changes
what the model is told up front (server instructions, the `cmux_exec` description, and
tool descriptions in `--surface all`); text inside `cmux.docs` answers comes from the
binary, so port a winning overlay to Rust and run again on the rebuilt binary.

A run writes `results.jsonl`, `summary.md`, and per sample `transcript.json` and
`row.json` under `--out`. Outputs hold terminal text from your shell; keep them out of git.

## Add a case

Cases are JSON lines in `cases/<area>.ndjson`. Fields: `id`, `area`, `kind` (`bad`
reproduces a mistake, `guard` protects good behavior, `control` is ordinary work),
`source` (where it happened), `experience` (the mistake in one sentence), `prompt`,
optional `context` (a system reminder before the prompt), `setup` (agent-evals setup
steps: `split-right`, `tab`, `workspace`), `files` (written to the scratch directory),
`surfaces` (default all), `noApp`, and `expect`.

Add the case before the fix: it must fail on the old text and pass on the new.
No user data in cases; use `/home/user` and `acme/app`.

## Template

Refresh `templates/claude.json.gz` when Claude Code changes its prompt: capture one
`/v1/messages` body with cmux's MCP server connected (a logging proxy in front of
`ANTHROPIC_BASE_URL`), then `bun tests/tool-evals/trim-capture.mjs <capture.json>
tests/tool-evals/templates/claude.json.gz`. It drops memory, skills, user tools and home
paths, and refuses to write a template with private data left in it.
