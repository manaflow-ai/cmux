# Extension ecosystem, provider registry, and defaults packs

Status: proposal

## Problem

cmux already has useful built-in actions, workspace commands, surface buttons,
and the Markdown viewer. A project-scoped note primitive is proposed in #4331,
but is not part of the current main tree. The local pack loader now lets a
project or global `cmux.json` reuse declarative entries. It does not yet
define how a pack names itself, how an intent selects an implementation, how a
user inspects or replaces cmux's defaults, or how an external implementation is
trusted.

This RFC defines those boundaries. The first implementation remains local and
declarative: a pack can add or override JSON configuration, while cmux keeps
ownership of intent dispatch, layout, lifecycle, and security. Providers are
adapters behind that boundary, not native plug-ins and not a second scheduler.

## Goals and non-goals

The design must provide:

- stable identifiers for built-in actions, intents, providers, routes, and
  default entries;
- a deterministic resolver that can explain which pack and provider won;
- inspectable, reviewable defaults changes with an undo receipt;
- local and Git-backed packs with a lockable, offline-readable manifest;
- explicit capabilities and exact-source trust for commands, files, network,
  and webviews;
- one shared route path for the command palette, CLI, socket, restore, and
  future sidebar contributions.

The first release does not load arbitrary native code, execute TypeScript
manifests, expose a marketplace, or silently grant a provider access to the
whole filesystem. A provider cannot replace cmux's lifecycle or create a second
execution scheduler.

## Terms

**Intent** is a public cmux operation such as `cmux.markdown.open`,
`cmux.note.open`, or `cmux.diff.open`. cmux owns its validation, target
selection, focus policy, lifecycle, and result shape.

**Provider** is a named implementation of one provider kind. A provider may be
built into cmux or run as a bounded filesystem, webview, or stdio adapter.

**Route** binds an intent to a provider. A route can choose a provider by
scope, but it cannot change the intent's public parameters or return contract.

**Pack** is a versioned directory or file containing declarative defaults,
routes, provider declarations, and capability metadata. Existing
`cmux.pack.json` files remain valid as packs without a manifest; they are
treated as version `1` anonymous packs during migration.

**Defaults** are the effective built-in entries after cmux applies its bundled
defaults and the configured pack layers. Runtime/session state is not part of a
pack and is never written by a defaults command.

## Stable identifiers

New IDs are immutable API names. They are ASCII, lowercase, dot-separated, and
limited to `[a-z0-9][a-z0-9-]*`; an optional `@major` suffix is used only for a
provider protocol version. Display names, titles, file paths, and Git URLs are
not identities.

The first-party namespace is reserved for cmux:

| Entity | Form | Examples |
| --- | --- | --- |
| Intent | `cmux.<domain>.<verb>` | `cmux.markdown.open`, `cmux.note.open` |
| Built-in action | `cmux.action.<name>` | `cmux.action.new-terminal` |
| Provider kind | `cmux.provider.<domain>` | `cmux.provider.markdown-render` |
| Built-in provider | `cmux.provider.<domain>.<name>` | `cmux.provider.markdown-render.builtin` |
| Route | `cmux.route.<intent>` | `cmux.route.markdown-open` |
| Default entry | `cmux.default.<area>.<name>` | `cmux.default.surface-tab-bar` |

Existing built-in action IDs are a compatibility exception: current canonical
IDs such as `cmux.newTerminal`, `cmux.newBrowser`, and `cmux.splitRight` remain
stable canonical IDs. New registry metadata records those IDs as legacy
first-party IDs, and the proposed kebab-case `cmux.action.*` names are aliases
only when a future migration explicitly declares them. A pack cannot rename a
built-in action by supplying a second spelling. Diagnostics always show the
existing canonical ID and any alias together.

Third-party packs use a reverse-domain namespace they control, for example
`com.example.review.diff` and `com.example.provider.diff-render`. Pack IDs are
unique installation identities: two packs with the same pack ID are a doctor
error unless they are the same locked revision. Entry IDs are different: a
higher-precedence pack may intentionally override a lower-precedence action,
route, provider, or default entry with the same stable ID. The resolver records
that override in provenance, while two declarations of the same entry ID in
one layer remain an error.

Provider kinds are also stable IDs, not free-form labels. Built-in kinds use
the `cmux.provider.<domain>` form in the table (for example,
`cmux.provider.diff-render`); a third-party kind uses its own reverse-domain
namespace. The short names in prose such as “diff renderer” are display terms
only. `doctor` rejects a provider whose kind is not registered or whose kind
namespace is owned by another pack.

Existing wire names are compatibility aliases. For example, the v2 socket
method `markdown.open` and CLI verb `markdown open` map to the canonical intent
`cmux.markdown.open`; the same mapping applies to any existing unprefixed
intent. The coordinator accepts both spellings, but provenance and new pack
routes use the canonical ID. Removing a wire alias requires a separately
versioned API change.

Built-in aliases keep existing config working. For example, `newTerminal` and
`cmux.newTerminal` continue to resolve to the same action while diagnostics
report the canonical ID. Aliases are read-only and cannot be introduced by a
pack.

## Pack manifest

The optional `cmux.pack.json` manifest describes ownership and compatibility.
The existing `actions`, `ui`, and `commands` keys remain at the top level so
current packs do not need a rewrite.

```json
{
  "$schema": "https://cmux.app/schemas/pack-v1.json",
  "schemaVersion": 1,
  "id": "com.example.review",
  "name": "Review workflow",
  "version": "1.2.0",
  "description": "Review actions and a diff renderer for this repository.",
  "requires": { "cmux": ">=0.20.0 <1.0.0" },
  "capabilities": ["readWorkspace", "gitDiff", "runCommand"],
  "providers": {
    "com.example.provider.diff": {
      "kind": "cmux.provider.diff-render",
      "driver": "stdio",
      "command": "review-diff-provider",
      "protocol": "cmux.provider.diff@1",
      "capabilities": ["gitDiff", "runCommand"]
    }
  },
  "routes": {
    "cmux.diff.open": {
      "provider": "com.example.provider.diff",
      "fallback": "cmux.provider.diff-render.builtin",
      "allowFallback": true
    }
  },
  "actions": {},
  "ui": {},
  "commands": []
}
```

`id`, `schemaVersion`, and `version` are required for an installed pack and
optional for an inline legacy pack. `requires.cmux` is checked before any entry
is applied. Unknown keys are preserved for forward compatibility only when they
are inside a provider's driver-specific `config` object; unknown top-level keys
are diagnostics and do not activate the pack.

The `$schema` URL in the example is reserved for the versioned schema that a
future implementation must publish. It is not a live URL today. Until that
schema is shipped, the bundled validator is authoritative and examples must be
treated as a proposal rather than an installable manifest.

The pack-level `capabilities` list is an upper bound for every provider and
entry in that pack; it is not itself a grant. Each provider must declare its
own least-privilege capability list, and its effective set is the intersection
of the provider list, the pack ceiling, and the intent's allowed set. A provider
with no declaration has no capabilities and cannot be activated. Actions that
do not invoke a provider may declare their own capability requirements in their
typed action definition.

Routes use either the legacy string form (provider ID only) or this object
form:

```json
{
  "provider": "com.example.provider.diff",
  "fallback": "cmux.provider.diff-render.builtin",
  "allowFallback": true
}
```

`provider` is required. `fallback` is optional and must name a built-in
provider of the same kind. `allowFallback` defaults to `false`; it may be true
only when the intent contract marks fallback as safe. Route scope comes from
the declaring layer (global or project), and a project route always outranks a
global route. Unknown route fields are diagnostics and disable that route.

Pack references stay local in the first phase. A Git install materializes a
checked-out directory and records its exact commit; `cmux.json` still points at
that local directory. HTTP(S) URLs in `packs` remain rejected by the loader.

## Provider registry

The registry is an app-owned, read-only snapshot built during config resolution.
It contains the built-ins plus validated provider declarations from the winning
pack layers:

```text
ProviderDescriptor {
  id:             stable provider id
  kind:           provider-kind ID, such as cmux.provider.notes-store or cmux.provider.diff-render
  driver:         builtin | filesystem | webview | stdio
  protocol:       provider protocol id and major version
  source:         bundled | installed-pack | global-config | project-config
  capabilities:   declared capability set (intersected with the pack ceiling)
  config:         driver-specific, non-executable metadata
}

RouteDescriptor {
  intent:         stable cmux intent id
  provider:       provider id
  scope:          global | project
  fallback:       optional built-in provider id
  source:         declaration path and pack fingerprint
}
```

The registry does not expose mutable provider objects to UI code. A route
request goes through one coordinator:

```text
resolve(intent, context)
  → validate context and capability grant
  → select highest-precedence route in the context
  → select provider, or declared built-in fallback
  → invoke with a bounded request and cancellation
  → return the intent's cmux-owned result
```

Every consumer uses that coordinator. The command palette, CLI, v2 socket,
session restore, and sidebar must not each resolve a provider independently.
Provider failure falls back only when the route explicitly declares a built-in
fallback and the intent marks fallback as safe. A failed write never silently
replays against another store.

### Protocol scope

This RFC specifies the registry boundary, not a universal provider wire
protocol. `protocol` values are versioned references whose request, response,
error, framing, handshake, and cancellation schemas must be published with the
provider kind before a non-builtin driver is accepted. A provider kind owns its
typed payload schema; the coordinator translates that payload to the stable
cmux intent result and never forwards a raw socket or app object. Until a kind
schema exists, only the `builtin` driver is valid for that kind.

The first external-driver follow-up must define, at minimum, a bounded
handshake that returns the provider and protocol IDs, capability echo, and
maximum request size; a framed request/response envelope with request IDs and
typed errors; cancellation acknowledgement and a deadline after which cmux
terminates the process or closes the webview; and a capability-scoped payload
for each intent. Those schemas are separate reviewable contracts, not implied
by the registry manifest example below.

### Driver contracts

Drivers are introduced in this order:

1. **builtin** — an in-process implementation registered by cmux. This is the
   only driver that can participate in the first notes and Markdown migration.
2. **filesystem** — a confined path under the project or pack root. It can
   read/write only the declared subpath and cannot execute a command.
3. **webview** — a URL with an explicit origin allowlist. It receives a
   capability-scoped `window.cmux` bridge and no ambient app or filesystem API.
4. **stdio** — a child process launched with an argument array, a bounded
   handshake, a private environment, request deadlines, output limits, and an
   explicit termination policy. It remains unavailable for a provider kind
   until that kind's protocol schema has landed.

No driver accepts shell fragments in a route. The `command` field for `stdio`
is an executable name or absolute path; arguments are a separate array. PATH
lookup, if enabled for a user-approved provider, is resolved once and recorded
in diagnostics.

## Resolution and precedence

The effective configuration is resolved in this order, from lowest to highest
precedence:

1. bundled cmux defaults;
2. installed packs, in the order recorded by the pack lock;
3. global `~/.config/cmux/cmux.json` and its local pack references;
4. project `.cmux/cmux.json` and its local pack references;
5. runtime/session state.

Within one layer, later pack entries override earlier entries by stable ID.
Direct entries in a config file override its referenced packs. Action metadata
uses a field overlay and retains unspecified fields from the lower layer. UI
defaults and routes use the same per-entry overlay rules when their typed
models support it. Workspace command definitions currently use first-wins
precedence by command name; the registry must preserve that behavior in the
compatibility slice and may add explicit command overlays only in a versioned
pack schema. A route may point only to a provider that survived validation in
the same or a lower layer.

The resolver emits provenance for every effective entry: canonical ID,
declaration path, pack ID/version, fingerprint, and the fields that were
overridden. This makes `defaults diff`, diagnostics, and trust prompts explain
the same result.

## Capabilities and trust

Capabilities are declarations, not permissions. The coordinator grants only the
intersection of the provider declaration, the intent's allowed set, and the
user's trust decision.

| Capability | Meaning | Default for a project pack |
| --- | --- | --- |
| `readWorkspace` | Read files below the project root | prompt once per fingerprint |
| `writeWorkspace` | Write files below the project root | prompt per fingerprint |
| `writeCmuxNotes` | Write `.cmux/notes` through the note store | prompt per fingerprint |
| `runCommand` | Start the declared stdio command | prompt per fingerprint |
| `network` | Connect to declared origins | prompt per fingerprint |
| `openWebview` | Create a webview for a declared origin | prompt per fingerprint |
| `gitDiff` | Read Git metadata and diff content | prompt once per fingerprint |
| `readGitMetadata` | Read repository identity and branch metadata | prompt once per fingerprint |
| `readGlobalConfig` | Read files under the global config root | always prompt |
| `writeGlobalConfig` | Modify global config or installed packs | always prompt |

The trust key is the SHA-256 fingerprint of the canonical manifest bytes, the
complete content digest of every declared pack file, the resolved pack root,
the installed Git commit when one exists, the project root (or global scope),
and the capability/path/origin scope. A path or display name alone is not a
trust identity. Project-local packs never inherit global trust, and a global
pack gets a separate decision for each project root it accesses. A changed
manifest, any declared pack file, commit, provider command, or declared origin
requires a new decision.

For a `stdio` provider, the grant is also bound to the executable that will
actually run: its canonical path, file identity, SHA-256 of its bytes, and the
resolved argument and environment allowlist are included in the approval
record. PATH lookup is resolved before prompting and the selected executable is
revalidated immediately before launch. Replacing the file, changing its
contents, changing the selected PATH target, or changing its arguments creates
a new fingerprint and requires a new decision. A provider cannot retain a
previous grant by keeping the same command string.

The prompt names the provider, intent, capability, path/origin, executable
identity when applicable, and action. A denied or unavailable capability is a
typed failure visible to the caller; it does not fall back to a more privileged
provider. The existing action trust store remains the persistence mechanism for
command-backed actions until the provider registry has its own storage boundary.

Every provider request carries the approved registry revision and fingerprint.
When a pack is disabled, removed, updated, or replaced, cmux publishes a new
registry revision and revokes grants associated with the old fingerprint. The
coordinator cancels in-flight requests, terminates stdio processes it owns,
closes provider webviews, and refuses new network requests for the revoked
revision. A provider may finish a read already returned to cmux, but it cannot
start another operation from that snapshot. Reload therefore cannot leave a
removed provider with a live command process or webview.

## Defaults commands

Defaults commands are read-first and produce machine-readable receipts. They
operate on the effective declarative defaults, never on runtime/session state.

```text
cmux defaults show [--json]
cmux defaults diff [--against <pack-or-path>] [--json]
cmux defaults eject --to <directory> [--force]
cmux defaults use <directory> [--preview] [--receipt <path>]
cmux defaults reset [--preview] [--receipt <path>]
```

- `show` prints the winning ID, provider, source, version, and capability
  summary. It never opens a provider or runs a command.
- `diff` compares effective values and provenance. It reports additions,
  removals, field changes, route changes, and capability changes; output is
  stable JSON suitable for review.
- `eject` writes a complete, editable pack with a manifest and only the
  effective declarative entries. It does not copy runtime IDs, credentials,
  caches, or machine paths. The target must be a new directory unless
  `--force` is explicit.
- `use` changes one global defaults-pack reference. `--preview` performs
  parse, schema, capability, and trust checks without publishing. A successful
  mutation writes atomically and returns a receipt containing the before and
  installed pack reference, target path, fingerprint, and revision.
- `reset` removes only the cmux-managed defaults reference. It preserves a
  user's unrelated `cmux.json` keys and refuses an undo when the target changed
  after the receipt was created.

These commands share the existing config writer lock, source revision check,
JSONC preservation, and conditional undo rules. A failed validation or trust
decision publishes nothing. No defaults command clones a Git URL; installation
is a separate `cmux pack` operation.

## Pack install, update, and doctor

The first remote distribution path is Git, with no marketplace service:

```text
cmux pack install <git-url> [--ref <commit-or-tag>]
cmux pack list [--json]
cmux pack update [<pack-id>]
cmux pack remove <pack-id>
cmux pack doctor [<pack-id>] [--json]
```

Installation clones into `~/.config/cmux/packs/<pack-id>/`, verifies the
manifest, records the exact commit and content fingerprint in
`cmux.packs.lock.json`, and leaves the pack disabled until the user chooses
where to reference it. Tags and branches are resolved once; updates require an
explicit command. Offline `list`, `show`, `diff`, and `doctor` work from the
lock and cached manifest without network access.

`doctor` checks schema compatibility, duplicate pack IDs and same-layer entry IDs, dependency cycles, path
confinement, executable resolution and byte identity, declared origins,
capabilities, and lock integrity. It reports one stable diagnostic code per
issue and never runs a provider as part of diagnosis.

## Notes, Markdown, and Diff migration

The first provider registry migration keeps existing behavior byte-for-byte:

| Intent | Built-in provider | Safe fallback |
| --- | --- | --- |
| `cmux.note.open` (after #4331) | `cmux.provider.notes.filesystem` | none for writes; read-only list may use the built-in note store |
| `cmux.markdown.open` | `cmux.provider.markdown-render.builtin` | bundled Markdown renderer |
| `cmux.diff.open` | `cmux.provider.diff-render.builtin` | bundled diff viewer |

When the note primitive from #4331 is available, its note store remains the
authority for note identity, project-root resolution, attachments, and writes.
A custom note provider can supply a read projection only until it implements the
note protocol and passes the same write/restore tests. Markdown and diff
providers receive a file or bounded content descriptor, not an arbitrary path
from a webview. Existing CLI and socket verbs keep their result shapes; only
their internal route changes.

## Failure, diagnostics, and compatibility

- Invalid packs are isolated. The current legacy `CmuxConfigStore` reports the
  invalid source and removes that pack's entries on reload; the registry
  migration must preserve that observable behavior for legacy actions and
  commands. A future transactional registry snapshot may retain the last valid
  provider routes, but only after it has an explicit compatibility test and a
  diagnostic that distinguishes retained state from newly loaded state.
- Missing providers produce `provider_unavailable` with the provider ID,
  intent, and recovery command. A route with no fallback never opens a
  different surface type.
- A provider timeout cancels its request and records a bounded diagnostic. It
  cannot keep a process or webview alive after cancellation.
- A pack dependency cycle, load budget violation, duplicate pack ID, or
  same-layer duplicate entry ID is a pack error, not a reason to reject the
  user's unrelated config. Cross-layer entry overrides are valid only when the
  resolver can show their precedence and provenance.
- Existing packs with only `actions`, `ui`, and `commands` continue to load as
  anonymous legacy packs. Their existing precedence, watcher behavior, source
  attribution, and trust ownership remain unchanged.

Diagnostics expose the effective registry and provenance through the existing
config diagnostics path and `cmux config` JSON output. They do not include
provider command arguments, environment secrets, note bodies, or file contents.

## Implementation slices

1. **Contract and registry model**: add typed manifest, provider, route, and
   capability values in the settings/config boundary; preserve the current
   legacy loader and add registry provenance tests.
2. **Read-only visibility**: implement `defaults show` and `defaults diff`,
   plus `pack list` and `pack doctor`. No mutation or provider execution.
3. **Safe defaults mutation**: implement `eject`, `use`, and `reset` through
   the existing transactional writer and receipts. Add rollback and conflict
   tests before any UI.
4. **Built-in routing**: route Markdown and the note primitive through the
   registry while keeping their CLI/socket contracts and restore behavior.
5. **Filesystem and webview drivers**: add confined, capability-checked
   drivers with fixture providers and cancellation tests. Filesystem access
   must resolve every path beneath the declared root without following a
   symlink out of it, open files with no-follow semantics where available, and
   revalidate the root and file identity at use time so a rename or symlink swap
   cannot escape the grant.
6. **Git distribution**: add install/update/remove and lock integrity checks;
   network access is explicit and never part of config reload.
7. **Stdio driver and trust UI**: add the handshake, process limits, prompts,
   diagnostics, and end-to-end tests. Publish the template and example packs
   only after these contracts are stable.

Every slice must include a behavior-level test for the shared resolver and at
least one entrypoint test. A route change is incomplete until CLI, socket,
palette, and restore paths either use it or explicitly document why they do not.

## Decisions and acceptance criteria

The initial format is JSON/JSONC only. TypeScript manifests may be considered
after the capability and trust boundary has shipped, but they are not part of
the pack protocol. Project routes are supported immediately because the
project-local pack is the unit users can review and commit; global routes fill
gaps but cannot override a project route.

Webviews use a narrow `window.cmux` bridge with declared origins. Localhost HTTP
is an implementation detail of a webview driver, not a provider API. A provider
must not receive a raw control socket or an unrestricted app object.

The first defaults pack includes only entries that already have stable behavior
and tests: built-in actions, surface-tab-bar defaults, new-workspace menu
defaults, Markdown/diff viewer settings, and note defaults once the note
primitive is on main. Credentials, window positions, open surfaces, and agent
session state are excluded.

The RFC is accepted when a reviewer can answer, from `defaults show` and
`doctor`, which declaration won, what it can access, how to undo it, and which
cmux-owned intent will receive the result. A provider implementation is not
accepted merely because it can render a panel; it must preserve those answers
through reload, restore, failure, and uninstall.
