# Replayable UI workflows

`workflow.py` runs a versioned synthetic journey with native CUA and gallery steps.
Both adapters return the same state/edge, assertion, evidence and metric vocabulary.
The existing CUA activity store owns native events and frames; this tool indexes
them without recording typed text, copying raw accessibility trees, or introducing
another event store. Gallery evidence remains in the existing matrix artifact.

Run on a fleet worker through `cmux-ci`, never on an agent host. These workflows
are on-demand verification, not a new merge or display gate.

```sh
python3 scripts/cmux-next/workflows/workflow.py check scripts/cmux-next/workflows/examples/gallery-combobox.json
python3 scripts/cmux-next/workflows/workflow.py run scripts/cmux-next/workflows/examples/gallery-combobox.json --context /private/context.json --out /private/receipts/build-a
python3 scripts/cmux-next/workflows/workflow.py replay scripts/cmux-next/workflows/examples/gallery-combobox.json --baseline /private/receipts/build-a/receipt.json --context /private/build-b.json --out /private/receipts/build-b
python3 scripts/cmux-next/workflows/workflow.py list /private/receipts
python3 scripts/cmux-next/workflows/workflow.py compare /private/receipts/build-a/receipt.json /private/receipts/build-b/receipt.json
```

The output directory must not exist. Each step gets `STEP/receipt.json`; the run
gets `receipt.json` and `graph.json`. Replay also writes `comparison.json`. `list`
prints JSON lines with workflow, build, host, outcome and each step's artifact
links. File evidence paths are relative to the step receipt. Native activity
references retain their session and sequence identities and frame expiration.

## Manifest

Only synthetic source fixtures are supported. Keep real prompts, credentials,
private hostnames and captured data out of the manifest. A manifest contains:

- `workflowVersion: 1`, a stable `id`, and `fixture: "synthetic"`;
- `steps`, at most 30, each with a unique `id`, `driver`, `from`, `to`, `action`,
  explicit `target`, `args`, and nonempty `expect`;
- `untested`, explicit limitations for reviewers.

Each step's `from` must equal the preceding `to`. These names describe the intended
journey; the receipt records the observed state and assertions separately. A failed
edge does not prove its destination was reached. Remaining steps are unavailable
and never execute. Steps are not retried: an uncertain action must not be repeated.

`gallery.play` selects an existing entry and variant. Inputs and assertions remain
in that entry's existing Playwright `play`. It requires `expect: {"play":"passed"}`
and empty `args`. A screenshot-only variant cannot pass. The example uses
`ui.combobox/keyboard`.

## Runtime context and evidence

Keep the context file private, outside the checkout:

```json
{
  "source_sha": "<40-character source commit>",
  "artifact": "<immutable fleet artifact ID or build tag>",
  "host": "<fleet worker ID>",
  "environment": {
    "viewport": {"width": 1000, "height": 800},
    "scale": 2,
    "theme": "dark",
    "locale": "en-US",
    "density": "comfortable",
    "reducedMotion": true
  },
  "gallery_dir": "/private/pinned-gallery"
}
```

Build the gallery with the repository's normal gallery build on the fleet. The
directory must contain `frame.html`; its observed revision must match `source_sha`.
The matrix's existing `CMUX_GALLERY_IN_VM=1` admission is required and is never
enabled by this tool. Gallery scale is the matrix's 2x capture scale, not UI zoom.
The optional `engine` is `chromium` (default) or `webkit`.

Timing and pixel hashes are evidence, not semantic equality. Gallery comparisons
include each after-step and final AX digest of the synthetic fixture, so changed
accessible content cannot pass as equivalent merely because its actions succeeded.
Fixtures must use fixed data and time; dynamic content would make those digests
diverge. Native AX digests remain evidence only. Comparison also uses
step identities, transitions, action outcomes, observed semantic state and
assertions. It reports the first divergent field. Different manifests or rendering
environments are incomparable; source commit, artifact and host may differ.
Missing observations never establish equivalence. Repeating a failed assertion can
be semantically equivalent but still returns a failing replay exit code.

Receipt directories are private (0700), JSON receipts 0600. Runtime launch
credentials and action payloads are not copied into receipts. Native frames retain
the CUA store's redaction and retention from
[`computer-use.md`](../../../../plans/cmux-next/computer-use.md#5-retention-redaction-remote-frames-d19).
These explicitly requested run bundles are exports: the existing export rule
applies, so they are not automatically deleted or published. Native original-store
references can expire; frames already exported into the requested bundle remain
inspectable. An absent or expired frame at export time makes evidence unavailable.

## Focused verification

From the owning PR, run the portable adapter and comparison tests on the fleet:

```sh
cmux-ci test -- python3 -m unittest discover -s scripts/cmux-next/workflows -p 'test_*.py'
```

The real Playwright evidence test is
`scripts/gallery-matrix/workflow-evidence.test.ts`; it requires the matrix's locked
dependencies and Chromium on the worker. It drives an actual button and checks
the before/after screenshot files and changed AX digest. A live gallery example
and a native run require the respective pinned artifacts and native consent.

## Native configuration

The native adapter supports `native.observe` and `native.click` with empty `args`.
Typing and keyboard actions are not supported: they would need an additional
verified focus contract. A target has `fixture`, `role` and `name`. The name is
matched exactly against the current AX label/title/name/description; an ambiguous
match stops the step. A click uses the current snapshot's `element_token` when
available, otherwise its `element_index`, together with the fixture PID/window.

`expect` contains boolean assertions selected from `visible`, `checked`, `enabled`
and `focused`. Here `visible` means the named element is present in the bounded AX
snapshot; it is not a pixel-occlusion claim. `checked` reads the checkbox/radio AX
value. `enabled` and `focused` are available only if the helper actually returns
those boolean fields; missing values fail assertions. Raw values and labels are
not persisted. AX digests hash the roles alone, never text or hashes of text.

Set `native_config` in the private runtime context to a mode-0600 JSON file owned
by the runner. Its shape is:

```json
{
  "driver": "legacy",
  "source_sha": "<same 40-character source commit as context>",
  "artifact": "<same immutable fleet artifact ID as context>",
  "app": "/private/isolated-fixture.app",
  "artifact_metadata": "/private/downloaded-artifact-metadata.json",
  "mcp": {
    "command": "/private/tagged-app/Contents/Resources/bin/cmux-cua",
    "args": ["mcp"],
    "env": []
  },
  "activity": {
    "socket": "/private/tagged-helper.sock",
    "token_env": "WORKFLOW_CUA_LAUNCH_TOKEN"
  },
  "targets": {"toggle": {"pid": 123, "window_id": 456}}
}
```

Use the MCP command/arguments/environment supplied by the app's authenticated
agent launch, not a standalone helper. The runner must remain within that launch's
allowed process ancestry. The token environment variable contains its existing
launch credential; the adapter never requests a host credential. It sends actions
only over MCP. Its activity socket client has a fixed read-only allowlist:
`activity_sessions_list`, `activity_timeline`, and `activity_frame`, using the
documented authenticated envelope. No default socket, permission override, daemon
launch, new recorder or product setting change is performed.

The metadata file accompanies the immutable fleet artifact and contains
`source_sha`, `artifact` and `executable_sha256` (SHA-256 of its main executable).
The adapter compares it to the context, hashes the downloaded executable, checks
`CMUXCommit` when the bundle carries it, and verifies that each fixture PID runs
that exact executable. A context declaration alone is insufficient.

`native-example.json` is a schema/example template, **not an existing app fixture
or a live verification claim**. It requires a separately built synthetic app
fixture with a checkbox named “Synthetic toggle”, immutable fleet metadata and
the pinned source identity. The same adapter can address a synthetic state in a
tagged product app. Neither target is launched by this adapter. A live run remains
unavailable until the fleet launcher supplies and verifies that fixture.

The existing `legacy` driver is supported; upstream v2 does not provide this
activity store. Before the first mutation, the adapter checks permissions and
reads existing activity. Session ownership comes from the helper's recorded
`agent.proxy_pid`, not a session name asserted by the workflow. Every linked event
must have the same session, actor, tool, target PID/window and a fresh sequence.
Both before and after observations require non-expired, readable helper frames.
The explicitly requested run bundle exports those existing redacted thumbnail bytes
as `before.png`/`after.png` (or `.jpg`), mode 0600, with their SHA-256 and original
session/blob/size/expiration references. It does not ask for an additional capture
or start a recorder. The bundle also contains `cua-events.json`: the exact linked
redacted `cmux-cua-core::activity::model::Event` records as a JSON array in the
helper's existing schema. The receipt index carries format and export-retention
provenance; event records are not rewritten into another event model. Only the
authenticated activity response is exported, never a raw MCP reply. Unexpected
raw payload fields, raw target labels and serialized result replies are refused.

The receipt contains before/after semantic state and roles-only AX digests next to
these exports, so a failed assertion is inspectable without the original helper
store. `before-events.json` preserves the initial observation if the later action
is refused or its outcome becomes unknown. A permission denial, MCP error or
approval request ends the step with no subsequent app/status reads; only evidence
already retrieved is retained, and no after-state is invented.

The contract was checked against the pinned engine
[`e8a8dbfd45a5d050058e7340f97ffe6f157c3128`](https://github.com/manaflow-ai/cmux-cua/tree/e8a8dbfd45a5d050058e7340f97ffe6f157c3128):

- `libs/cmux-cua/rust/crates/platform-macos/src/tools/get_window_state.rs:54`
  requires `pid` and `window_id`, and returns structured `elements` plus a screenshot.
- `libs/cmux-cua/rust/crates/platform-macos/src/tools/click.rs:90` declares
  `pid`, `window_id`, `element_index` and `element_token`.
- `libs/cmux-cua/rust/crates/cmux-cua-core/src/activity/model.rs:95` and `:109`
  declare `AgentIdentity.actor` and `proxy_pid`; `:227` places that identity in
  `SessionRecord.agent`; `:305`–`:315` declare the event correlation fields.
- `libs/cmux-cua/rust/crates/cmux-cua/src/activity_daemon.rs:99` derives the
  authenticated actor from the socket peer's process identity; `:278`–`:320`
  implement the activity reads. These are daemon methods, not MCP tool names.
