# cmux-next native workflows

Status: PR 1 of 4 (the runtime crate) in review, 2026-10-20. Design: section 3 of
the nightly release-train design (teamleaderleo/leo-workspace#624,
`workstreams/cmux-next-nightly-train.md`). Decision there: native workflows are
the code-mode runtime ([code-mode.md](code-mode.md)) plus an `agent()`
primitive, not a second engine.

## The script

A workflow is a `.cmux/workflows/<name>.workflow.js` file with the Claude Code
workflow API, so a script moves between the two unchanged:

- `export const meta = {name, description, phases}`
- `agent(prompt, {label, phase, schema, harness, model, effort, on})`: the final
  reply as text, or with `schema` the validated object; `null` when the agent
  failed for good (after the stall policy).
- `parallel(thunks)`: a barrier; a task that throws is `null`; never rejects.
- `pipeline(items, ...stages)`: each item through every stage with no barrier;
  a stage gets `(previous, item, index)`; a stage that throws drops its item to
  `null`.
- `phase(title)` and `phase(title, body)`, `log(text)`, `args`, `budget`
  (`total` is `null`; no token budget yet).

Added for cmux: `machine(command, {on})` returns `{exit, log}` and rejects on a
non-zero exit (the error has `exit` and `log`), and code mode's `cmux.call` /
`cmux.<tool>`. `workflow()` (nesting) is not available yet.

The engine is code mode's QuickJS with the same rule: no file system, network,
process or timer access. `Date.now()`, `new Date()` and `Math.random()` throw,
so a resumed run takes the same path; pass times in `args`.

## Journal and resume

Each run has a journal (`journal.jsonl`): `run` per execution with the script's
sha256, `started` when a step starts on the host (with the host's handle),
`done` when it finishes (in finishing order). A step's key is a hash of its
kind, input and options, without `label` and `phase`.

Running the script again against the journal resumes it. Step `n` is answered
from the journal when the journal finished step `n` under the same key and no
earlier step of this execution differed: the longest unchanged prefix, as Claude
Code resumes. Cached results come back in the order they first finished, so the
script sees the same interleaving. A step that started but never finished runs
again with its handle in `Step::resume`, so the host can reattach (acpmux
sessions stay resumable). Failed steps are not journaled, so a resume retries
them. A torn last line (a crash mid-write) is cut off on open.

## Schemas

`agent(prompt, {schema})` needs `{type: "object"}` at the root; a schema that
does not compile throws at `agent()`. The reply's JSON is the whole text, else
the last fenced block that parses, else the outermost braces. On a mismatch the
runtime sends the same session one follow-up with the errors and the schema;
a second mismatch fails the step (`null`).

## Stall policy

`stall::Watch` turns an agent's events into a decision: no event (or a
permission waiting) for `quiet` (10 min) nudges once, then restarts the session
on another route or harness (`acpmux continue`), then fails. A usage limit or a
route error skips the nudge. The host owns applying it.

## Limits

64 MiB heap; 30 s of computation without a step or call; 2,000 `cmux.call`s
per execution (a resume starts the count again); 1,000 agents per run; 16
steps running at once (more queue); 4,096 items per `parallel()`/`pipeline()`.

## PRs

1. `cmux-tui/crates/cmux-workflow`: engine, driver, journal and replay,
   schemas, stall policy, all behind a `Host` trait, with a fake-host test
   suite. No caller yet.
2. Daemon-owned runs: `cmux workflow start|status|pause|resume|list`, runs under
   the cmux state root (`workflows/runs/<id>/journal.jsonl`), and the host: an
   `agent()` step is an acpmux session (any harness), `machine()` a command on
   the chosen machine or role (builds never on interactive machines), the
   stall watch fed by acpmux events. Pause stops new steps and stops running
   sessions; app relaunch resumes.
3. `cmux_workflow` code-mode tool (start, status, pause, resume) next to
   `cmux_docs` and `cmux_exec`.
4. Sidebar run group behind a default-off debug toggle: the run is a group,
   phases are headers, each `agent()` is a workspace to open or take over,
   `machine()` steps are rows with their tail. Lawrence signs off on the
   sidebar part; a203 reviews the journal against org workflows.
