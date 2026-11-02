# CMUX Next UI workflow corpus

## Purpose

CMUX Next already has three useful evidence paths:

- gallery entries define web component states and plays;
- `scripts/cmux-next/media/tour.py` drives a tagged app through CLI actions and emits a
  per-step manifest, screenshots, and a bounded video;
- live scripts use the debug socket for native behavior and `debug.window_snapshot`.

The missing layer is a durable corpus of complete user journeys. A journey should be
replayable against a pinned artifact, inspectable as a state graph, and useful to a person
or an agent reviewing a failure months later. This plan defines that layer. It does not make
a screenshot normative, replace the gallery contract, or require recording every exploratory
click in source control.

The corpus is CMUX Next-first. Classic may be used as a comparison artifact, but a Classic
result never satisfies a Next journey.

This plan composes with [`computer-use.md`](computer-use.md), which already defines the CUA host
activity store, event timeline, thumbnails, redaction, session attribution, and agent activity
pane. CUA events remain the authoritative record for computer-use tool calls. This corpus adds
the outer product journey: native app and webview state, user-visible receipts, lifecycle
transitions, and bounded media-tour artifacts. A run that includes CUA links its `cuaSessionId`
and event sequence range instead of creating a second CUA event format.

## Priority journeys

The first corpus should cover the paths that combine the most state transitions with the
highest cost when they fail. Each journey runs once with synthetic fixtures and once with the
relevant disconnected, delayed, or restored state when that state is supported.

| ID | Priority | Journey | Required outcome |
| --- | --- | --- | --- |
| `launch-restore` | P0 | Launch, choose a workspace, quit while sessions are kept, relaunch, and restore a terminal and browser surface | The same workspace and surface identities return exactly once; no orphan process or duplicate tab is left behind |
| `workspace-layout` | P0 | Create and rename a workspace, select it from Home/sidebar, split right and down, move focus, close and reopen a surface | Selection, focus, split direction, and close/restore receipts agree after every action |
| `terminal-input` | P0 | Create a terminal, type a command, submit it, inspect output, scroll, copy/paste, resize, and interrupt a running command | Input reaches the intended pane, output is ordered, scroll and focus remain stable, and interruption has a visible receipt |
| `tabs-and-browser` | P0 | Open terminal and browser tabs, navigate, create a split, switch tabs, move a tab, use back/forward/reload, and close/reopen | Tab identity and browser location remain distinct; a failed page is represented as an error state with retry |
| `command-palette` | P0 | Open the palette, search, move through results with keyboard and pointer, invoke an action, dismiss, and reopen | Search, selection, invocation, dismissal, and focus return are deterministic |
| `agent-pane` | P0 | Open an agent pane, start a fixture turn, stream tool progress, expand/collapse output, approve or reject a request, stop, and resume | Turn/session identity, pending states, receipts, and recovery are visible; no duplicate turn is created |
| `sidebar-and-history` | P1 | Filter/sidebar search, switch sections, inspect recent/closed/history entries, reopen one, and clear a scoped entry | Row state and opened destination agree; paging and empty/error states are bounded |
| `overlays-and-settings` | P1 | Open settings, menus, notifications, key-hint/help, and update/account surfaces; resize around each overlay and dismiss it | Overlay ownership, keyboard focus, outside dismissal, and narrow-width layout are correct |
| `disconnect-reconnect` | P1 | Delay or drop the control/agent connection, observe stale and reconnecting states, then recover | The UI names the connection generation, does not silently discard a mutation, and converges to a fresh snapshot |
| `profile-and-config` | P1 | Switch profile/config, change a reversible setting, relaunch, and return to the original profile | State is scoped to the selected profile and never leaks into another profile or Classic |
| `accessibility-and-narrow` | P1 | Run the P0 actions at narrow, normal, and wide widths with keyboard navigation, reduced motion, and VoiceOver/AX assertions where available | Targets remain reachable, names and roles are stable, and motion does not hide completion |
| `remote-session` | P2 | Attach to a paired/remote workspace, handle latency and reconnect, then close only the owned surface | Ownership, authorization, and remote errors are explicit; local surfaces remain unaffected |

A journey may be split into bounded tours for the existing 30-step media limit. The corpus
entry keeps the parent journey ID so an agent can reconstruct the complete path.

## Workflow manifest

A manifest is the executable contract for one bounded journey. JSON is the interchange format;
YAML is acceptable for hand-authored fixtures when converted and checked before execution.
Manifests are data. They must not contain credentials, real prompts, private hostnames, or
unredacted personal content.

```json
{
  "corpusVersion": 1,
  "id": "terminal-input",
  "title": "Terminal input and recovery",
  "priority": "P0",
  "surface": "cmux-next-native",
  "source": {
    "repo": "manaflow-ai/cmux",
    "ref": "<commit-or-build-id>",
    "artifact": "<immutable-artifact-id>"
  },
  "environment": {
    "os": "macOS <version>",
    "viewport": {"width": 1440, "height": 900},
    "scale": 2,
    "theme": "dark",
    "locale": "en-US",
    "reducedMotion": false,
    "engine": "native-debug-snapshot"
  },
  "fixture": {
    "seed": "terminal-input-v1",
    "network": "offline",
    "clock": "fixed",
    "agent": "mock"
  },
  "preconditions": ["private scratch config", "no unrelated app instance"],
  "steps": [
    {
      "id": "write-command",
      "action": "terminal.write",
      "target": {"workspace": "fixture-workspace", "pane": "shell"},
      "args": {"text": "printf 'hello\\n'\\r"},
      "expect": {
        "state": "terminal.output",
        "receipt": "terminal.command.finished",
        "contains": "hello"
      },
      "capture": ["before", "after"],
      "settleMaxMs": 2000
    }
  ],
  "invariants": [
    "the selected pane owns the input",
    "surface identity does not change during output",
    "every mutation has one receipt or one explicit error"
  ],
  "teardown": ["close owned app", "verify debug socket is gone"],
  "untested": ["real provider authentication", "hardware VoiceOver" ]
}
```

Required manifest fields are `corpusVersion`, `id`, `source`, `environment`, `fixture`,
`preconditions`, `steps`, `invariants`, and `teardown`. Every step has a stable `id`, an
explicit target, an action, an expected semantic state, and either a receipt or a declared
reason that no receipt exists. `optional` is allowed only for a capability that the runner
has probed as unavailable; an optional failure is still recorded.

The runner must reject unknown fields, duplicate step IDs, missing targets for mutating actions,
real network URLs in offline fixtures, and manifests that omit a source ref or artifact. It
writes a normalized manifest beside the run so later agents do not depend on the hand-authored
format.

## State graph

The manifest steps are edges in a state graph. The graph is stored in the normalized run receipt
and can also be checked before execution. Nodes describe observable semantic state, not pixels.

Node kinds currently required:

- `lifecycle`: launching, ready, quitting, restoring, crashed;
- `home` and `workspace`: selected workspace, sidebar section, and revision;
- `surface`: terminal, browser, file, agent, or split container with stable identity;
- `overlay`: palette, menu, settings, notification, account, or dialog with focus owner;
- `agent`: session/turn status, pending approval, stream cursor, and error/retry state;
- `connection`: connected, delayed, reconnecting, disconnected, or stale generation;
- `error`: user-visible failure with retry or recovery action.

Every node carries `revision`, `identity`, and `observedAt` from the monotonic run clock. Edges
carry `stepId`, `action`, `target`, and `receiptId`. A graph check fails when an action mutates
a different identity than the target, when a state transition occurs without a receipt, or when
a later snapshot cannot converge to the expected revision. A pixel difference can annotate a node,
but it cannot make an otherwise missing state transition pass.

Example normalized edge:

```json
{
  "from": {"kind": "workspace", "identity": "ws:fixture", "revision": 4},
  "edge": {
    "stepId": "split-right",
    "action": "layout.split",
    "target": "pane:shell",
    "receiptId": "r-0007"
  },
  "to": {
    "kind": "surface",
    "identity": "split:fixture:1",
    "revision": 5
  }
}
```

The runner should prefer typed debug snapshots, action replies, accessibility trees, and daemon
receipts. OCR and computer vision are review aids for a human or model, not the primary oracle.

## Capture and artifact layout

Each run has a short immutable run ID and is written outside the source checkout. CI or the
capture service can upload the bundle to the existing gallery or artifact store.

```text
<artifact-root>/cmux-next/<journey-id>/<source-sha>/<run-id>/
  manifest.normalized.json
  graph.json
  events.jsonl
  steps.jsonl
  screenshots/
    000-before-launch.png
    010-after-terminal-input.png
  video/
    000-launch-restore.mp4
    010-terminal-input.mp4
  frames/
    010-terminal-input/000123.jpg
  traces/
    010-terminal-input.trace.zip
  contact-sheet.png
  receipt.json
```

Video names are deterministic within a run:

```text
<step-index>-<phase>-<slug>.mp4
```

A `video/index.json` sidecar records `runId`, `journeyId`, `sourceSha`, artifact ID, step range,
frame rate, dimensions, codec, start/end monotonic timestamps, capture engine, redaction status,
and SHA-256. The recording is bounded to the step or a small group of steps. Never append an
unbounded desktop recording to a workflow artifact. Existing media tours may continue to emit
their current `frames/` and published video; the normalized receipt maps those files into this
layout without renaming an existing public artifact.

Screenshots and videos use synthetic fixtures by default. If a capture includes user data, the
run is private, the sidecar sets `redaction: required`, and publication is blocked until a
redacted derivative is produced. Logs and traces follow the same rule. The source repository
stores manifests, schemas, and small hand-authored fixtures, not generated recordings.

## Deterministic replay

Replay is a first-class operation, not a claim that a video can be played back into the app.
The runner must provide:

1. **Pinned identity.** Resolve the exact source commit and immutable app artifact before launch.
2. **Private state.** Use a scratch config, state directory, control socket, and fixture workspace.
3. **Stable fixtures.** Seed named workspace, pane, tab, browser, agent, and history identities.
4. **Controlled inputs.** Use the cmux CLI/debug protocol or Playwright locators with stable
   accessibility names. Do not use screen coordinates when a typed action exists.
5. **Controlled time and network.** Use a fixed clock where supported and stub provider/browser
   responses. A real network probe must be a separate journey with a recorded endpoint allowlist.
6. **Receipt waits.** Wait for a typed receipt or state revision, with a bounded `settleMaxMs`.
   Sleeps are allowed only as a capture delay after the semantic wait.
7. **Idempotent retry.** A step may retry only when no receipt was observed and the action declares
   itself safe to repeat. A mutation with an unknown result stops the run and records `uncertain`.
8. **Cleanup proof.** Quit only the app started by the run, verify the socket/process is gone, and
   preserve cleanup failures in the receipt.

The first implementation can adapt `scripts/cmux-next/media/tour.py`, `scripts/cmux-next/*-e2e.py`,
`debug.window_snapshot`, and the existing gallery play runner. A future `cmux next workflow`
command can expose `list`, `check`, `run`, and `show` without changing the underlying manifest.

## What future agents consume

An agent reviewing a run should not start with the video. It should:

1. load `receipt.json`, `manifest.normalized.json`, and `graph.json`;
2. find the first failed or uncertain step and read its `events.jsonl` window;
3. inspect the before/after screenshots and accessibility/state snapshot for that step;
4. open the bounded video segment and contact sheet to understand timing, pointer movement, and
   visual context;
5. rerun the exact command or workflow against the same artifact if the environment is available.

The agent-facing index should expose `journeyId`, source/artifact, verdict, failed step IDs,
artifact links, and untested states. It should support queries such as `agent-pane + approval`,
`disconnect-reconnect + narrow`, and `all P0 failures since <source-sha>`.

A review finding uses this shape:

```json
{
  "journey": "tabs-and-browser",
  "step": "reopen-failed-page",
  "severity": "S1|S2|S3|observation",
  "expected": "the failed page has a retry action",
  "observed": "the tab reports host loss and has no retry",
  "source": "<sha>",
  "environment": "<run-id>",
  "evidence": ["screenshots/021-after.png", "video/021-reopen-failed-page.mp4", "events.jsonl#842"],
  "replay": "cmux next workflow run tabs-and-browser --run <run-id>",
  "confidence": "confirmed|probable|unconfirmed"
}
```

This lets a later Codex, ChatGPT, or Claude session reproduce a bug from structured evidence,
while still giving the reviewer the video that explains what a human saw. Agents must preserve
the distinction between a confirmed failure, an unverified state, and a taste-level suggestion.

## Initial rollout

The executable adapter layer lives in
[`scripts/cmux-next/workflows`](../../scripts/cmux-next/workflows/README.md).
Its versioned synthetic manifests use one state/edge vocabulary for authenticated
legacy CUA and gallery plays. `run`, `replay`, `compare`, and `list` produce and
consume private step receipts and an indexed graph. Native receipts reference the
existing activity store; they do not replace `cua_event` or its retention policy.
The upstream CUA v2 helper has no activity store and reports unavailable rather
than fabricating evidence. The broader journey inventory below remains the rollout
guide; a manifest's `untested` list records what that run did not exercise.

1. Normalize the existing `core`, `new-tab`, and `agent-pane` media tours into manifests and
   receipts without changing their current published artifacts.
2. Add `launch-restore`, `workspace-layout`, `terminal-input`, and `command-palette` fixtures;
   run them on an owned GUI runner against one exact tagged build.
3. Add state snapshots and receipt IDs to each step, then generate a graph and contact sheet.
4. Add the disconnected/reconnecting and narrow-width variants after the P0 happy paths are
   green. Keep them separate so a network or layout failure cannot hide a basic workflow failure.
5. Publish one index page or artifact manifest linking the journey, source, screenshots, video,
   graph, and verdict. Keep raw recordings on the artifact service and retain only receipts and
   small fixtures in Git.

## Acceptance criteria

The corpus slice is ready for wider use when:

- every P0 journey has a checked manifest and a pinned source/artifact;
- a clean runner can replay a P0 journey twice with identical semantic graph and receipt output;
- every required step has a typed receipt or an explicit, reviewed exception;
- each run has screenshots, bounded video, events, graph, and cleanup evidence;
- a reviewer can locate the first failure from the index without opening the video;
- a future agent can rerun the failing journey from the recorded command and distinguish stale,
  unavailable, and confirmed states; and
- publication rejects private or unredacted artifacts and reports the rejection in the receipt.

The existing UI parity methodology remains the authority for component captures, viewport
matrices, and visual diffs. This corpus supplies complete journey coverage and replayable runtime
evidence around it.
