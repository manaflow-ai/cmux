# Extension ecosystem, provider registry, and defaults packs

Status: proposal

## Problem

cmux already has useful built-in actions, workspace commands, surface buttons,
the Markdown viewer, and project-scoped notes. The local pack loader now lets a
project or global `cmux.json` reuse those declarative entries. It does not yet
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

**Intent** is a public cmux operation such as `markdown.open`, `note.open`, or
`diff.open`. cmux owns its validation, target selection, focus policy, lifecycle,
and result shape.

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

IDs are immutable API names. They are ASCII, lowercase, dot-separated, and
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

Third-party packs use a reverse-domain namespace they control, for example
`com.example.review.diff` and `com.example.provider.diff-render`. A pack must
not redefine another pack's ID by changing its display metadata; an override is
explicitly recorded as an override of that stable ID.

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
      "kind": "diff.render",
      "driver": "stdio",
      "command": "review-diff-provider",
      "protocol": "cmux.provider.diff@1"
    }
  },
  "routes": {
    "cmux.diff.open": "com.example.provider.diff"
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
  kind:           provider kind, such as notes.store or diff.render
  driver:         builtin | filesystem | webview | stdio
  protocol:       provider protocol id and major version
  source:         bundled | installed-pack | global-config | project-config
  capabilities:   declared capability set
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
   explicit termination policy.

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
Direct entries in a config file override its referenced packs. A field overlay
retains unspecified fields from the lower layer, as the existing action and
command loader does today. Routes follow the same rule, but a route may point
only to a provider that survived validation in the same or a lower layer.

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
resolved pack root, and the installed Git commit. A path or display name alone
is not a trust identity. Project-local packs never inherit global trust. A
changed manifest, commit, provider command, or declared origin requires a new
decision.

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

`doctor` checks schema compatibility, duplicate IDs, dependency cycles, path
confinement, executable resolution and byte identity, declared origins,
capabilities, and lock integrity. It reports one stable diagnostic code per
issue and never runs a provider as part of diagnosis.

## Notes, Markdown, and Diff migration

The first provider registry migration keeps existing behavior byte-for-byte:

| Intent | Built-in provider | Safe fallback |
| --- | --- | --- |
| `cmux.note.open` | `cmux.provider.notes.filesystem` | none for writes; read-only list may use the built-in note store |
| `cmux.markdown.open` | `cmux.provider.markdown-render.builtin` | bundled Markdown renderer |
| `cmux.diff.open` | `cmux.provider.diff-render.builtin` | bundled diff viewer |

The note store remains the authority for note identity, project-root
resolution, attachments, and writes. A custom note provider can supply a read
projection only until it implements the note protocol and passes the same
write/restore tests. Markdown and diff providers receive a file or bounded
content descriptor, not an arbitrary path from a webview. Existing CLI and
socket verbs keep their result shapes; only their internal route changes.

## Failure, diagnostics, and compatibility

- Invalid packs are isolated. cmux keeps the last valid snapshot and reports
  the invalid source; it does not partially apply a new route set.
- Missing providers produce `provider_unavailable` with the provider ID,
  intent, and recovery command. A route with no fallback never opens a
  different surface type.
- A provider timeout cancels its request and records a bounded diagnostic. It
  cannot keep a process or webview alive after cancellation.
- A pack dependency cycle, load budget violation, or duplicate stable ID is a
  pack error, not a reason to reject the user's unrelated config.
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
   drivers with fixture providers and cancellation tests.
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
