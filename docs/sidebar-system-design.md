# cmux presentation system

Status: proposed cross-frontend architecture. This document is the
authoritative design for sidebar, right-panel, Dock, and pane-mounted views.
The implementation plans and authoring guides link here. A route or field
described as proposed is not an implemented API.

## Decision

cmux has one semantic presentation system. It does not have one singleton
sidebar with unrelated exceptions for the TUI, the macOS right panel, custom
sidebars, and Dock.

The system has one source of truth for shared resources, one catalog of view
providers, one identity model for mounted views, one layout tree, and one
typed action path. Each frontend renders that model with its own chrome and
its own ephemeral state.

```text
resource graph + event log
          |
          v
provider catalog
          |
          v
view instances + layout profiles
          |
          v
region mounts
          |
          v
frontend presentation state
          |
          v
TUI, macOS, iOS, web, or remote renderer
```

This gives a user three complementary controls:

1. Splits show complementary views at the same time.
2. A profile strip switches between named arrangements.
3. A context menu and command catalog manage what is mounted.

No one of these controls is the discovery mechanism for the others. Every
control calls the same typed action reducer.

## Why the old three-choice model is incomplete

The useful question is not “split, right-click, or tabs?” The question is
which object is being changed:

| User intent | Correct object | Primary control |
| --- | --- | --- |
| See workspaces and agents together | Layout tree | Split |
| Move from work to review | Layout profile | Profile strip or command |
| Add a provider, move it, or reset it | Mount and instance | Context menu, palette, or command |
| Open a full terminal or browser tool | Interactive surface region | Dock layout controls |
| Ask an agent what is visible and act on it | Semantic projection | Catalog, snapshot, invoke, and wait |

An expert would reject a split-only design because narrow terminals hide lower
views and give no durable discovery path. An expert would reject a
context-menu-only design because keyboard users, remote clients, and coding
agents cannot reliably discover hidden state. An expert would reject tabs for
every view because tabs hide information that should be compared and create a
nested navigation problem. The design uses each mechanism for its actual job.

## Vocabulary and identity

The terms below are normative. Existing names remain compatibility aliases
until migration is complete.

### Resource graph

The resource graph is the authoritative shared model of workspaces, machines,
panes, tabs, terminals, browsers, agents, notifications, and provider events.
It belongs to the daemon or host that owns the resource. A frontend may cache
and project it, but it does not invent a second agent or workspace store.

Provider-owned external data may stay outside the daemon graph. In that case
the provider exposes a namespaced resource projection with its source,
revision, expiry, and permission boundary. The host must not copy an external
record into a fake shared workspace or agent merely to make a renderer easier.

Every resource has an opaque stable ID and a revision. Array positions are
presentation data and must never be used as a durable target.

### View provider

A view provider describes a kind of projection or interactive tool. It is not
itself a mounted view. Built-in workspace and agent lists, interpreted custom
sidebars, compiled extensions, Files, Feed, Cloud, and similar tools all
publish provider descriptors.

A provider descriptor contains:

| Field | Purpose |
| --- | --- |
| `provider_id` and `schema_version` | Stable namespace and compatibility boundary |
| `title_key`, icon, and summary | Localized human label and machine-readable description |
| `kind` | `projection` for resource rows, or `surface` for an interactive terminal/browser tool |
| `placements` | Regions where the provider may be mounted |
| `scope_schema` | Valid workspace, machine, agent, filter, and sort parameters |
| `dependencies` | Resource types and event categories that invalidate the provider |
| `actions` | Typed verbs, target selectors, schemas, preconditions, and safety class |
| `attention` | Queries that produce counts and reasons, not only colors |
| `size` | Minimum, preferred, and maximum dimensions plus narrow-mode behavior |
| `trust` and `permissions` | Source, renderer isolation, data access, and mutation grants |
| `lifecycle` | Mount, suspend, resume, reload, failure, and unmount behavior |

Provider IDs are namespaced by the owner. A file called `agents.js` is not an
identity. The host assigns an ID that remains stable when the file is moved or
renamed, while the file path remains mutable metadata.

Action safety classes are `read`, `focus`, `mutate`, and `destructive`. A
provider may expose a destructive action in its descriptor, but an unattended
caller needs an explicit policy grant and a confirmation-capable receipt. A
human click is not proof that an autonomous caller has permission.

### View instance

A view instance is a provider plus a concrete scope and presentation identity.
The same provider can have several instances, for example:

- `agents.current-workspace`, filtered to the selected workspace;
- `agents.all-workspaces`, sorted by attention;
- `agents.blocked`, filtered to blocked or waiting sessions.

Instances have stable `instance_id` values. Their scope and local settings are
stored once. Profiles reference instance IDs instead of copying full view
definitions. This prevents duplicate configuration, ID collisions, and
profile-switch bugs.

### Layout profile

A layout profile, shown to users as a **layout**, is a named arrangement of
instances in a layout tree. It is not a second resource graph and it does not
start a second detector.

```text
profile Work
  split vertical, weight 2
    workspaces.current
  split vertical, weight 1
    agents.current-workspace

profile Review
  split horizontal
    workspaces.current
    agents.blocked
```

The current TUI term `sidebar.profiles` maps to layout profiles. “Deck” is
not a new primitive. Desktop right-panel modes map to profiles with one active
instance, while Dock profiles contain interactive surface leaves.

### Region and mount

A region is a physical or logical host slot owned by one frontend window. The
initial region catalog is:

| Region | Default role | What it may contain |
| --- | --- | --- |
| `primary-sidebar-left` | Navigation | Lightweight projection views |
| `secondary-sidebar-right` | Tools and inspection | Projection views and bounded tool panels |
| `dock-right` | Persistent tools | Terminal and browser surfaces in a Bonsplit tree |
| `pane` | Main content | Terminal, browser, transcript, or custom panel surfaces |
| `mobile-panel` | Small-screen inspection | A profile or one focused instance at a time |

A region mount binds one profile to one region. The same provider or instance
may be mounted in two regions, but each mount has independent focus, scroll,
size, and visibility state. A surface provider may require one exclusive mount
because it owns a live terminal attachment.

The Dock is therefore part of the presentation system, but it is not forced
into the row-view renderer. Its leaves use the same IDs, actions, receipts,
and layout concepts while retaining terminal and browser lifecycle rules.

### Frontend presentation state

Presentation state belongs to `(frontend_projection_id, window_id, region_id)`.
It includes the active profile, focus path, selection, scroll cursor, filter
text, collapsed nodes, local visibility, rail widths, split fractions, badge
read markers, and renderer errors.

The daemon must not gain a global active sidebar profile or globally active
workspace for this purpose. Two windows and a remote client must be able to
show different profiles at the same time. Durable state restores a preference;
an attachment lease carries live render state; neither changes shared topology.

## Composition rules

### Splits are for simultaneous context

Splits use the existing layout-tree primitive. A leaf references one instance.
Each split has an axis, ordered children, a positive weight, and a minimum
usable size. Ratios persist per profile, mount, and frontend window.

When space is insufficient, the solver may compact or suspend a low-priority
leaf. It must leave an overflow marker that names the hidden view, its reason,
and the action that restores it. Silent disappearance is a correctness bug.
The user can pin a view to prevent automatic compaction when the region has
enough space to honor the minimum size.

The default agent-oriented `Work` profile includes a trusted Agents instance
below Workspaces with a smaller weight. It has a compact empty state when no
agent exists. An explicit user layout remains authoritative, so an old config
that lists only Workspaces does not gain an unexpected pane. This trade-off
keeps new agent users informed without rewriting existing layouts.

### Profile strips are for mutually exclusive arrangements

Each region shows a compact profile strip when it has more than one available
profile. The strip contains the active layout name, attention summary, and an
add/manage affordance. A narrow TUI uses the name plus an overflow count. It
never removes the only path to a hidden profile.

The desktop right-sidebar mode bar is the existing renderer for this concept.
It should consume provider and profile descriptors from the shared registry,
not grow a second enum-only catalog. The TUI may render a one-row header or a
palette entry because a terminal has different space limits.

Profiles are not per-view tabs. A user who needs two agent scopes at once
creates two instances in one split. A user who needs different workflows
switches profiles.

### Context menus are management, not authority

Right-click is useful for local discovery. It must offer the same semantic
actions as the profile strip, keyboard, command palette, socket, and public
agent API:

- show, hide, mount, unmount, move, split, and resize;
- create, duplicate, rename, reset, and pin a layout or instance;
- choose scope, filter, sort, and attention policy;
- inspect provider version, trust, permissions, source, and errors;
- copy stable IDs and open a semantic details view.

The menu must not contain a private action path. A menu action that cannot be
represented in the catalog is incomplete.

### Custom providers compose with built-ins

An authored sidebar is a provider contribution. It does not replace the
entire built-in sidebar unless the user selects a legacy compatibility mode.
The host can mount it beside Workspaces or Agents, in the right region, or as a
pane surface when its descriptor permits those placements.

Each mount gets its own worker and lifecycle. A crashed custom provider cannot
remove or starve a built-in view in another mount.

Third-party providers are not auto-mounted merely because they are installed.
The catalog offers an explicit Add action, and a curated trusted provider may
request a default profile contribution. This trade-off protects privacy,
startup time, and terminal width.

## Agent system

Agent detection and agent presentation are separate layers:

```text
hook, screen detector, remote adapter
              |
              v
canonical agent resource + lifecycle events
              |
              v
agents provider instances, desktop panel, mobile panel, API snapshot
```

The canonical record carries an opaque agent ID, adapter kind, workspace and
surface binding, state, state start time, last activity, title, process and
transcript references when permitted, source, `updated_at`, and a monotonic
revision. A detector may add evidence and provenance. It must not create a
renderer-specific row format.

The provider derives attention from state and evidence. A badge says “3 need
input” and a semantic snapshot says which three, why, when the evidence was
updated, and which action can focus or inspect them. “Blocked” is a derived
attention reason, not a second incompatible agent state.

An agent row's default actions are `workspace.select`, `surface.focus`,
`agent.open-transcript`, `agent.mark-seen`, and `agent.copy-id`, subject to the
provider's declared permissions. Dragging a row is an optional renderer
gesture that invokes the same `agent.open` action as the keyboard, palette,
and CLI.

## Agent-facing contract

Agents must control the system from semantics, not pixels. The proposed public
resource operations are:

| Operation | Result |
| --- | --- |
| `frontend.presentation.catalog` | Providers, instances, profiles, regions, actions, permissions, attention summaries, and a catalog revision |
| `frontend.presentation.snapshot` | A bounded semantic tree with stable IDs, labels, values, bounds when known, actions, attention, source revisions, timestamps, staleness, and errors |
| `frontend.presentation.invoke` | An idempotent action receipt and the resulting local or authoritative revision |
| `frontend.presentation.wait` | A blocking wait for an operation, revision, event predicate, or attention change |

These names remain proposed until they have schemas, inventory entries, SDK
facades, and conformance fixtures. The existing raw frontend adapter is not a
substitute for this contract.

Every mutating request includes a caller-generated `operation_id` and may
include `expected_revision`. The receipt is one of:
`accepted`, `completed`, `rejected`, `unavailable`, or `indeterminate`.
`completed` states whether the action changed state or was a safe no-op. An
agent can retry an accepted or indeterminate operation without duplicating a
workspace close, profile switch, or provider mount.

Resource revisions, provider revisions, layout revisions, and frontend
presentation revisions are separate values. A receipt names which revision it
advanced. A client must not treat a local repaint as proof that a daemon-owned
mutation committed.

A snapshot uses cursor pagination and `since_revision`. Each leaf exposes a
stable target ID, human label, machine type, current value, action IDs and
parameter schemas, `source`, `updated_at`, `stale`, and `error`. The API must
also expose the reason a view is hidden or suspended. This lets an agent
diagnose “I do not see Agents” without reading a screenshot.

## Trust and capability boundaries

The registry is not permission to run arbitrary commands. Built-in providers
declare safe read and focus actions. A custom provider receives a capability
manifest with default-deny access to authentication, browser evaluation,
machine deletion, filesystem reads, and other destructive or sensitive verbs.
The user can grant a narrower capability set per provider source and revision.

In-process rendering is limited to trusted sources. Remote rendering is the
containment lane and has a smaller input and data surface. Trust changes create
a new provider revision and require a fresh mount decision. A warning-only
flag is not a security boundary.

## Authority, persistence, and lifecycle

- The daemon owns the resource graph, canonical events, provider records that
  represent shared data, and mutation receipts.
- The frontend owns focus, selection, scroll, geometry, local filters, and
  renderer state.
- Config files seed provider and profile definitions. A restored window
  snapshot wins over a seed, including an intentionally empty region. The
  normal precedence is restored window snapshot, project config, user config,
  built-in defaults. An explicit reset replaces the mounted state instead of
  merging stale values from lower-precedence sources.
- A config reload is not a hidden migration of active windows.
- A hidden projection view may suspend its renderer and event subscriptions,
  while retaining its instance and presentation state. A Dock terminal may
  remain alive because its surface lifecycle requires it.
- One frontend snapshot cache is shared by all views. Providers subscribe to
  declared dependencies, events are coalesced by revision, and rows are
  bounded or paged. A clock may tick locally; every provider must not poll the
  entire resource graph once per second.

## Migration plan

### Phase 0, contract and vocabulary

Land this document, add links from the data-driven sidebar, custom sidebar,
Dock, subagent, TUI configuration, native frontend, plugin, and programmability
documents, and mark proposed routes as proposed. Do not add a second profile
or provider enum during this phase.

### Phase 1, compatibility registry

Build a host registry adapter that turns current built-in views, desktop mode
descriptors, custom sidebar files, and the agent detector into provider
descriptors. Parse `sidebar.views`, `sidebar.columns`, and embedded
`sidebar.profiles` into stable instance IDs. Keep old keys readable and emit
warnings for index-based references.

### Phase 2, TUI composition

Keep the existing split geometry solver. Replace durable leaf references with
instance IDs, add the profile strip and overflow marker, and route keyboard,
mouse, palette, and socket actions through one reducer. Add the default Work
profile's compact Agents leaf for new configurations only.

### Phase 3, desktop and Dock composition

Back `CmuxExtensionSidebarSelection` and `RightSidebarMode` with descriptors.
Mount custom providers independently in left, right, or pane regions. Keep
Dock's terminal/browser surface tree and persistence rules, while adopting the
shared IDs, action receipts, and catalog.

### Phase 4, canonical agents

Normalize hook, screen-detector, and remote-agent adapters into one resource
and event contract. Make the TUI Agents view, desktop subagents panel, and
mobile panel projections of that record. Add evidence, provenance, attention
reasons, and stable focus actions.

### Phase 5, agent API

Add schemas and inventory entries for catalog, snapshot, invoke, and wait.
Generate SDK and CLI facades. Add idempotency, revision checks, bounded
pagination, permission errors, and disconnect behavior before advertising the
contract to autonomous agents.

### Phase 6, hardening

Measure provider evaluation, event fan-out, snapshot size, mount latency, and
memory at 100 and 1,000 resources. Add trust prompts, renderer containment,
crash isolation, migration rollback, and cross-frontend conformance tests.

## Acceptance criteria

The system is ready for general use when all of these are true:

- A new user can find and mount Agents without knowing a config key.
- Workspaces and Agents can be visible together, and two differently scoped
  Agents instances can coexist.
- A narrow terminal exposes every hidden view and the reason it is hidden.
- Profile switching, context menus, keyboard, palette, CLI, and drag gestures
  produce the same action receipt and state transition.
- A custom provider can fail, reload, or be untrusted without replacing native
  views or leaking undeclared data.
- Two windows can use different profiles without changing shared mux state.
- An agent can discover the active region, identify a row, invoke focus or
  inspection, wait for completion, and verify the resulting revision without a
  screenshot.
- The TUI, macOS, Dock, and mobile projections agree on agent identity,
  lifecycle, attention reason, source, and staleness.
- Hidden views do not consume a live polling loop, and a bounded snapshot does
  not grow with unbounded transcript or terminal output.

## Explicit trade-offs

The registry and stable instance IDs cost migration code and more durable
metadata. That cost buys composition, independent frontend windows, reliable
agent targeting, and safe retries. Keeping profiles as copied view definitions
would be cheaper for the first release, but experts reject it because reorder,
duplicate, and restore behavior diverge quickly.

The default Work profile adds a small Agents empty state for new users. It uses
some sidebar height and can be disabled by choosing Focus or editing the
profile. Hiding Agents by default would preserve space, but it would repeat the
current discoverability failure.

The public semantic API is a new protocol surface. Delaying it until the
desktop visuals look complete is cheaper short term, but experts reject that
order because UI-specific IDs and action paths then become difficult to undo.

No automatic third-party mounting is intentional. It adds one discovery step,
but prevents an installed provider from consuming data, width, CPU, or trust
without an explicit decision.

## Non-goals

- A universal renderer that makes a Dock terminal behave like a text row.
- A global active profile or global frontend focus field in mux topology.
- A marketplace before provider identity, permissions, lifecycle, and catalog
  contracts are stable.
- Pixel scraping as an agent control API.
- A promise that every historical child-agent relationship exists when the
  source adapter never observed it.
