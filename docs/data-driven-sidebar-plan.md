# Data-driven presentation implementation plan

Status: the TUI composition compatibility slice is implemented. The shared
provider registry and semantic frontend API remain proposed in this plan.

The presentation system is the source of truth for how built-in views,
authored sidebars, right-panel tools, Dock surfaces, and agent panels compose.
This plan covers the interpreted sidebar data and action bridge. It does not
define a second sidebar model.

## Goal

An authored provider must be able to discover the data it is allowed to read,
render bounded live projections, invoke typed actions, and react to relevant
events. A coding agent must be able to control the same provider through
semantic catalog, snapshot, invoke, and wait operations.

The host owns the resource graph, provider registry, permission checks, event
subscription, and action receipts. The interpreter owns only its declared view
tree and local state. A provider cannot assume that a field, command, or event
exists because another frontend happens to expose it.

## Current implementation

The v2 socket dispatcher (`TerminalController.processV2Command`) is the
existing authority for many reads and writes. `CmuxEventBus` is the existing
event source. `CustomSidebarDataContextBuilder` and the custom sidebar workers
already project a small workspace context, and `cmux(method, params)` already
reaches the dispatcher.

These facts reduce duplication, but they do not make the system complete:

- The TUI now has built-in Work and Focus profiles. Work stacks Workspaces and
  Agents, and the shared strip, overflow reasons, Restore, profile keys, mouse
  actions, and context menu use one profile-keyed reducer. Explicit legacy
  columns, views, profiles, and sidebar plugins keep their existing shape.
- This TUI reducer is frontend-local. It is not the future cross-frontend
  provider registry, action receipt, or semantic agent API.

- There is no provider catalog with stable provider and instance IDs.
- Command names and parameters are not exposed as a scoped capability schema.
- A context refresh does not identify its source revision, age, or error.
- The current event bridge and one-second refresh paths are not one dependency
  graph.
- A custom file can be selected in one host slot, but placement, mount
  identity, lifecycle, and trust are not explicit.
- TUI, desktop, and future mobile agent views can drift if they keep separate
  detector or row models.

The old goal, “expose all 248 commands and all hooks,” is therefore rejected as
the contract. A raw method count is not discoverability, safety, or a useful
view schema.

## Contract

### Provider descriptor

Every built-in or custom sidebar publishes a descriptor containing:

- stable namespaced `provider_id` and schema version;
- title key, icon, renderer kind, and supported placements;
- scope, filter, and sort schemas;
- resource and event dependencies;
- typed actions with parameter schemas, preconditions, and safety classes;
- attention queries and the narrow-size policy;
- trust source, permissions, and renderer isolation policy;
- mount, suspend, reload, failure, and unmount behavior.

Provider-owned external data remains namespaced and carries source, revision,
expiry, and permission metadata. The host must not copy it into a fake shared
resource to simplify rendering.

The descriptor is metadata. It does not start a process or grant a command.

### View instance and profile

An instance combines a provider with a concrete scope. Profiles reference
instance IDs in a split layout tree. The same provider may have multiple
instances, such as current-workspace Agents and all-workspaces Agents.

`sidebar.views`, `sidebar.columns`, and embedded `sidebar.profiles` remain
readable compatibility formats. The adapter assigns stable instance IDs and
records a migration warning when an old index is used as identity. New config
and APIs must reference IDs.

### Data snapshot

A snapshot is bounded and self-describing. It includes:

```json
{
  "provider_id": "cmux.builtin.agents",
  "instance_id": "agents.current-workspace",
  "revision": "frontend-revision-42",
  "updated_at": "2026-09-03T20:00:00Z",
  "stale": false,
  "items": [],
  "next_cursor": null,
  "error": null
}
```

Rows carry stable resource IDs, semantic labels, values, attention reasons,
available action IDs, source provenance, and any required bounds. Large
collections use cursors and limits. A hidden or suspended view reports its
state and reason instead of looking absent.

### Actions and receipts

The host exposes one action reducer to interpreted Swift, reactive JS, TUI
keyboard and mouse, desktop menus, command palette, CLI, and remote agents.
Every mutation has an operation ID and may have an expected revision. The
receipt is `accepted`, `completed`, `rejected`, `unavailable`, or
`indeterminate`. Completion says whether state changed or the request was a
safe no-op. Safety classes are `read`, `focus`, `mutate`, and `destructive`;
destructive actions require an explicit policy grant and confirmation-capable
receipt.

The default capability set is read, focus, selection, and safe navigation.
Authentication changes, browser evaluation, machine deletion, filesystem
access, and other sensitive verbs require an explicit trust grant. “All
commands” is never the default for an authored file.

### Events

The host subscribes once to the event bus and maps events to provider
dependencies. It coalesces updates by revision and sends only relevant
changes. Agent hooks and screen detectors enter the canonical agent resource
adapter; the sidebar does not interpret each producer independently.

## Implementation waves

### Wave 0, vocabulary and fixtures

Keep [sidebar-system-design.md](sidebar-system-design.md) authoritative. Add
contract fixtures for provider descriptors, instance IDs, layout profiles,
snapshot metadata, action receipts, stale data, permission errors, and event
revisions. Mark every future route as proposed until it has a schema and an
inventory entry.

Exit condition: a reviewer can identify the provider, instance, region, target
resource, operation, and revision in every example.

### Wave 1, host registry adapter

Create one registry adapter for:

- native TUI projections;
- macOS left-sidebar providers and right-panel modes;
- interpreted and compiled custom sidebars;
- the Dock surface provider;
- the canonical Agents provider.

Do not remove existing enums or config keys in this wave. Give each legacy
entry a descriptor and a stable compatibility ID. Keep separate worker
ownership for each custom mount.

Exit condition: the host can list all available providers and placements
without rendering or launching them.

### Wave 2, complete interpreted reads

Replace the hand-built four-key context with a `DataContextProvider` backed by
the same payload builders used by query methods. Add workspace, machine,
surface, pane, window, notification, feed, browser, and agent fields only when
their source has a clear owner. Include `source`, `revision`, `updated_at`,
`stale`, and bounded error information.

Expose known gaps through named fields or explicit unavailable errors. Do not
silently synthesize process, shell, transcript, or browser state from a slow
filesystem scan.

Exit condition: every documented data key has an owner, type, revision rule,
limit, and behavior when unavailable.

### Wave 3, event bridge and state engine

Subscribe through one host `EventBridge`. Expose recent events and derived
attention only within the provider's declared capability scope. Replace broad
one-second re-evaluation with dependency-driven invalidation. Keep a local
clock tick for elapsed labels when needed.

Add the host-owned state and binding engine for interactive controls. A state
write must still pass through the action reducer and return a receipt.

Exit condition: a workspace or agent update refreshes only dependent rows, and
an event can be traced from source revision to rendered provider revision.

### Wave 4, typed command catalog and trust

Generate a machine-readable action catalog from the implemented dispatcher and
frontend actions. The catalog includes parameters, selectors, preconditions,
permission class, idempotency, result type, and structured errors. The
interpreter receives only the provider's granted subset.

Use default-deny for sensitive namespaces. Add a per-source trust decision and
content revision. A changed source or grant causes a new provider revision and
does not inherit an old mount silently.

Exit condition: an authored provider can discover every action it may call and
receives a structured rejection for every action it may not call.

### Wave 5, semantic frontend API

Add proposed public operations after schemas are reviewed:

- `frontend.presentation.catalog`;
- `frontend.presentation.snapshot`;
- `frontend.presentation.invoke`;
- `frontend.presentation.wait`.

Generate CLI and SDK facades. Support `since_revision`, cursor pagination,
expected revisions, operation idempotency, disconnect recovery, and explicit
local-versus-authoritative revisions.

Exit condition: an agent can find the Agents instance, identify a row by stable
ID, focus or inspect it, wait for the receipt, and verify the resulting
revision without reading terminal pixels.

### Wave 6, performance and failure hardening

Measure provider evaluation, event fan-out, snapshot size, mount latency, and
memory at 100 and 1,000 resources. Suspend hidden projection workers, keep
Dock surface lifecycles where required, bound row counts, coalesce revisions,
and isolate remote renderer failures.

Exit condition: no hidden provider polls the full resource graph, no provider
can block a built-in view, and limits and failure states are visible in the
catalog and snapshot.

## Agent ergonomics requirements

An agent driver must be able to perform this sequence:

1. List regions and active profiles.
2. List provider and instance IDs, including hidden and suspended reasons.
3. Request a bounded semantic snapshot with a revision and cursor.
4. Choose an action from the row's declared actions and preconditions.
5. Invoke with an operation ID and expected revision.
6. Wait for completion or a relevant event.
7. Read the receipt and new snapshot revision.

The catalog must expose recommended next actions for attention states, but it
must not make an opaque autonomous choice such as closing a terminal. Human
labels, machine IDs, source evidence, timestamps, and permission errors must
appear together so an agent can explain its decision.

## Verification matrix

Behavior tests, not source-shape tests, cover:

- legacy config migration, profile switching, reorder, duplication, and stable
  instance IDs;
- split geometry, narrow overflow disclosure, and independent mount state;
- action parity across keyboard, context menu, palette, CLI, socket, and drag;
- catalog permissions, trust changes, stale snapshots, revisions, retries, and
  structured errors;
- one provider mounted in two regions and two scopes mounted in one split;
- custom provider crash, reload, suspend, unmount, and renderer isolation;
- canonical agent identity and attention parity across TUI, macOS, Dock, and
  mobile projections;
- cursor limits, event coalescing, and resource budgets;
- Dock surface creation and right-panel mode selection through shared IDs;
- two frontend windows using different profiles without changing shared mux
  active state.

## Decisions closed by this plan

The following alternatives are rejected:

- Expose every dispatcher method to every file. This fails least privilege and
  gives authors no useful capability explanation.
- Let a custom sidebar replace the native sidebar by default. This prevents
  composition and can hide critical workspace or agent state.
- Keep profile-local copied view definitions forever. This causes identity and
  restore divergence.
- Use the right-click menu as the only discovery path. It excludes keyboard,
  remote, and agent drivers.
- Poll all data every second. It wastes resources and still produces stale
  evidence.
- Store active profile or active resource in shared mux topology. Multiple
  windows would fight over one user's presentation.

## Residual risks

The registry introduces migration metadata and a new protocol surface. The
largest technical risk is inconsistent provider ownership during the desktop
and TUI adapter period. The mitigation is one descriptor fixture set and one
action receipt path before adding more providers. Agent history may still be
incomplete when a source adapter never observed a child session; the API must
report that evidence gap instead of implying a complete tree.

This plan intentionally does not choose a visual style for every frontend.
Visual chrome is renderer-local. The stable semantic model is the part that
must remain shared.
