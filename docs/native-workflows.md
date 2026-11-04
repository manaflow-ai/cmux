# Native workflows

A native workflow runs JavaScript in cmux's existing code-mode runtime. acpmux owns the run,
so its lifetime is independent of the chat turn that started it. Tool calls use the same
catalog, caller scope and permission checks as `cmux_exec`.

Save a workflow in your project's `.cmux/workflows/check.workflow.js`:

```js
export const meta = { name: 'Check', phases: [{ title: 'Review' }] };
const replies = await phase('Review', () => parallel(args.map(prompt => () =>
  agent(prompt, {
    schema: {
      type: 'object', properties: { summary: { type: 'string' } },
      required: ['summary'], additionalProperties: false,
    },
  })
)));
return await pipeline(replies, reply => reply.summary);
```

Start it from the project directory and read its result:

```sh
cmux --json workflow start check.workflow.js --args-json '["Review the last commit"]'
cmux --json workflow status <run-id>
cmux workflow pause <run-id>
cmux workflow resume <run-id>
```

`start` returns immediately with a run ID. `status` includes the pinned source hash, state,
activity handles and final outcome. With no ID it lists accessible runs. A start from an agent
chat belongs to that proven caller. A local terminal start creates a dedicated owner with
asking permissions; it grants no person authority. Pause and resume preserve the run ID.

The `cmux_workflow` tool takes `action: "start" | "status" | "pause" | "resume"`. Start takes
`name`, JavaScript `source` and optional JSON `args`; the other actions use `run_id`. It is
discoverable through `cmux.docs('cmux_workflow')` and callable through `cmux.call`.

## Workflow primitives

- `agent(prompt, options)` starts an acpmux session and returns that prompt's final reply.
  `schema` validates JSON output offline. A mismatch gets one correction prompt; another
  mismatch rejects the call. Harness, model, effort and route selection obey existing
  session policies. `stallMs` sets the inactivity deadline; the default is five minutes.
  Inactivity triggers one nudge, then one restart using a different configured
  `fallbackHarness` or `fallbackRoute`, then failure. Permission questions, capacity and
  account limits retain their existing approval and recovery paths.
- `machine(command, options)` runs a daemon-owned background command and returns its
  recorded output and exit status. A nonzero exit rejects the call. An interrupted launch
  whose outcome cannot be proved fails as uncertain instead of executing twice.
  Commands run locally by default. `on: "ci"` requires the installed authenticated
  `cmux-ci` placement adapter. It pins the repository, full source commit and relative
  working directory before submission, accepts an optional `targetWorker`, and reuses
  one keyed receipt when reconciling retries. Without that adapter, CI placement fails;
  it never falls back to running the command locally. See
  [#33778](https://github.com/manaflow-ai/cmux/issues/33778).
- `phase(title, fn)` runs a named phase. `parallel(tasks)` starts its callbacks together;
  each ready branch can continue independently. `pipeline(items, fn)` maps sequentially.
- `cmux.call`, `cmux.docs` and `console` retain the code-mode contract. Scripts have no
  filesystem, network or timer access. Read and mutate the app through catalog tools.

## Replay and recovery

The daemon pins source bytes and arguments when a run starts. Editing its file changes only
future runs. Each call reserves a durable identity using invocation order and a hash of its
prompt and options. Outcomes are saved before JavaScript sees them. Resume reevaluates the
pinned script and returns saved outcomes without dispatching those calls again, preserving
the original promise completion order.

A resume allows 2,000 fresh host calls, including raw tool calls and documentation reads;
saved calls spend none of that allowance. Reaching the allowance pauses the run. An explicit
resume gets a fresh allowance. The 64 MiB engine heap and compute watchdog remain safety
bounds. Clocks and randomness throw because they would change the replay path.

Only one runner owns a run's journal. Pause fences its generation before interrupting its
recorded children. A daemon restart resumes running records with fresh launch credentials;
credentials are never saved in the workflow journal. Raw tool calls interrupted before an
outcome was saved are uncertain and require inspecting their effect before a new run.

Signing, notarization and publication stay in protected GitHub Actions jobs. A workflow may
dispatch a job and wait for its result; do not pass publishing or signing secrets to a script.

Sidebar grouping and phase presentation are a separate UI change.
