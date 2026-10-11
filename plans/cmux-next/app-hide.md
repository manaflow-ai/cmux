# Install, enable, hide: per-user app state

Status: proposal, lane 3 helper, 2026-10-02. Implements Platform v2 V9 (app-platform.md PR 16821 section 12) and critique C7. Owner of the state: `UserDO` (team installs: the install record in `TeamDO`, the member's enable and hide overlay in `UserDO`), mirrored by the Rust app supervisor (V8). The Swift code in `Packages/macOS/CmuxNext/Sources/CmuxNextAppPermissions/Install/` is the reference model, the client-side filter and the UI; the owners port the reducer 1:1.

## 1. Requirements (Lawrence)

- First-party apps are installed by default. Samples are opt-in and never default-installed.
- Install but hide: a hidden app has no presence in the sidebar, palette, menus, titlebar, menu bar, open-with lists, feeds or App Store "Installed" badges. CLI, MCP and automations may still run it when the user allows that (`hiddenAccess`, default all true, shown only in Settings > Apps).
- Unhide from anywhere: Settings > Apps, the palette ("Show Hidden Apps", always present) and the CLI.
- Hide is distinct from disable and from uninstall. It is personal and synced.

## 2. State and wire shapes

One record per (user, app). A removed app keeps its record (`source: null`) so revisions stay monotone for every mirror. The owner also keeps, per user, `defaults_offered` (the apps first-launch bootstrap has offered; kept forever, never pruned) and the receipts of accepted ops (keyed by client and idempotency key; pruned after the replay window). The examples below are the contract: `AppStateWireTests` decodes and re-encodes every block tagged `json app-state-<kind>`.

Record (`app.changed` carries it whole):

```json app-state-record
{"app": "cmux/usage", "source": "default", "enabled": true, "hidden": true, "hidden_access": {"cli": true, "mcp": false, "automations": true}, "revision": 7}
```

```json app-state-record
{"app": "kestrel/snippets", "source": null, "enabled": false, "hidden": false, "hidden_access": {"cli": true, "mcp": true, "automations": true}, "revision": 4}
```

Ops (catalog family `app`, risk mutate-own). The request body is `{op, idempotency_key, params}`; the actor (client install id, origin, team admin) comes from the connection, never from the body.

```json app-state-op
{"op": "app.install", "idempotency_key": "6f1c-1", "params": {"app": "acme/board", "source": "user"}}
```

```json app-state-op
{"op": "app.remove", "idempotency_key": "6f1c-2", "params": {"app": "cmux/usage", "confirmed": false}}
```

```json app-state-op
{"op": "app.hide", "idempotency_key": "6f1c-3", "params": {"app": "cmux/usage"}}
```

```json app-state-op
{"op": "app.set_hidden_access", "idempotency_key": "6f1c-4", "params": {"app": "cmux/usage", "mcp": false}}
```

| Op | Params | Origins accepted | Notes |
| --- | --- | --- | --- |
| `app.install` | `{app, source}` | `user` (source `user`); team admin with origin `user` (source `team`); the owner itself (`system`, source `default`) | no-op when installed; `source: default` is offered once per user, ever (`defaults_offered`) |
| `app.remove` | `{app, confirmed}` | `user`, `cli` | team install: admin only; default install with `confirmed: false` hides instead (outcome `converted_to_hide`) |
| `app.enable`, `app.disable` | `{app}` | `user`, `cli` | needs installed |
| `app.hide`, `app.unhide` | `{app}` | `user`, `cli` | needs installed |
| `app.set_hidden_access` | `{app, cli?, mcp?, automations?}` | `user` | omitted fields stay |
| `app.list` | `{include_hidden?}` | any | read; hidden apps only with `include_hidden` |

Origins use the OWNERSHIP-PRINCIPLES names `user | cli | mcp | script | remote` (`script` covers automations). `mcp`, `script` and `remote` never change app state. `system` is not a request origin: it is the owner running its own first-launch bootstrap. Idempotency keys are scoped by client; the prefix `default-install:` is reserved for the owner and refused from clients (`idempotency.reserved_key`).

Result, then `request-settled {transaction, sequence}`:

```json app-state-commit
{"outcome": "converted_to_hide", "events": [{"event": "app.changed", "record": {"app": "cmux/usage", "source": "default", "enabled": true, "hidden": true, "hidden_access": {"cli": true, "mcp": true, "automations": true}, "revision": 8}}]}
```

```json app-state-commit
{"outcome": "applied", "events": [{"event": "app.changed", "record": {"app": "acme/board", "source": null, "enabled": false, "hidden": false, "hidden_access": {"cli": true, "mcp": true, "automations": true}, "revision": 3}}, {"event": "app.storage_removed", "app": "acme/board"}, {"event": "app.grant_removed", "app": "acme/board"}]}
```

Outcomes: `applied`, `no_change`, `replayed`, `converted_to_hide`. Rejects (`code`, plus `origin` or `source` where it applies): `app.origin_not_allowed`, `app.not_installed`, `app.admin_only`, `app.source_not_allowed`, `idempotency.key_reused`, `idempotency.reserved_key`. A rejected op is not recorded; a replay of its key is evaluated again.

```json app-state-reject
{"code": "app.origin_not_allowed", "origin": "mcp"}
```

```json app-state-reject
{"code": "app.admin_only"}
```

Swift: `AppInstallState`, `AppStateOp`, `AppStateActor`, `AppStateOrigin`, `AppStateEvent`, `AppStateCommit`, `AppStateReject`, `AppStateStore` (`defaultsOffered`), `AppStateReducer.apply(_:to:actor:)`, `AppDefaultInstalls`.

## 3. Invariants (for the Rust and DO owners)

| # | Invariant | Swift test |
| --- | --- | --- |
| I1 | `hidden ⇒ installed` for every record after every commit | `everyCommitKeepsTheInvariants` (300 seeds) |
| I2 | `enabled = false` overrides everything: no user surface, no run from any channel, hidden or not | `disabledOverridesEverything` |
| I3 | Uninstall clears `enabled`, `hidden` and `hidden_access`, and emits storage and grant removal in the same commit | `everyCommitKeepsTheInvariants` |
| I4 | A team install is removed and installed only by a team admin; members may hide, unhide, disable, enable | `teamMembersNeverRemoveOrInstallTeamApps` (100 seeds), `memberTeamInstallIsRefused` |
| I5 | An unconfirmed Remove of a default install hides it. Bootstrap offers each default app once per user, ever (`defaults_offered`), so a removal sticks through later reinstalls, removals and receipt pruning | `defaultInstallsSkipSamplesAndAreOfferedOnce`, `aRemovedDefaultAppStaysRemovedAfterReinstallRemoveAndPruning` |
| I6 | Hide and unhide change only `hidden` (and `revision`) and emit only `app.changed`: never grant, storage or layout records | `everyCommitKeepsTheInvariants` |
| I7 | Replaying a key from the same client with the same op has no effect (`replayed`, no events); the same client and key with another op is `idempotency.key_reused`; another client's same key is independent; clients may not use `default-install:` keys | `everyCommitKeepsTheInvariants`, `clientsCannotUseTheReservedDefaultInstallKeys` |
| I8 | `mcp`, `script` and `remote` never change app state; installs and `set_hidden_access` are user origin only | `everyCommitKeepsTheInvariants`, `defaultInstallsSkipSamplesAndAreOfferedOnce` |
| I9 | An op changes only its own app's record; the revision rises by one exactly when the record changes | `everyCommitKeepsTheInvariants` |
| I10 | Convergence: three clients (user, CLI, team admin) with mirror + intent log, reordered and duplicated ops and events, retries with the same key, bootstrap in between: when queues drain, every mirror equals the owner and the owner equals an independent reference model of the arrival order | `clientsConvergeOnTheOwner` (300 seeds) |
| I12 | The wire examples in section 2 decode and re-encode to the same JSON | `AppStateWireTests` |
| I11 | First launch installs exactly the non-sample first-party apps; a second launch emits nothing | `defaultInstallsSkipSamplesAndAreOfferedOnce` |

## 4. The central filter

One filter in the action registry and the scene router, never per surface (`AppPresenceFilter`). It works on implemented interfaces (Platform v2 V2) and on catalog fragment ops with their declared surfaces.

| Item | User surfaces while present |
| --- | --- |
| `cmux.section/1` | sidebar, palette ("Add <App> Section"), menus |
| `cmux.status/1` | titlebar, or menu bar when `placement: menuBar` |
| `cmux.palette.scope/1`, `cmux.search.provider/1` | palette |
| `cmux.editor/1`, `cmux.viewer/1`, `cmux.opener/1`, `cmux.diff.renderer/1` | open-with, menus |
| `cmux.feed.source/1` | feeds |
| catalog fragment op | the surfaces it declares |
| any of the above | App Store "Installed" badges |
| `cmux.fs.provider/1`, `cmux.credential.provider/1`, servers | none |

Present = installed, enabled and not hidden. Consumers take the allowlist `AppPresenceFilter.presentApps(states)`: an app without a record is not present. Run rule (`app.run`, an MCP tool of the app, an automation trigger):

| State | user, remote | cli | mcp | script (automations) |
| --- | --- | --- | --- | --- |
| not installed | `app.not_installed` | same | same | same |
| disabled | `app.disabled` | same | same | same |
| hidden | `app.hidden` | `hidden_access.cli` | `hidden_access.mcp` | `hidden_access.automations` |
| present | runs | runs | runs | runs |

A hidden app's sections keep their layout records and render nothing, so unhide restores them exactly.

## 5. Actions and surfaces (for the actions lead)

| Action | Palette title | CLI | Right-click placements | MCP |
| --- | --- | --- | --- | --- |
| `app.hide` | "Hide <App>" (one per visible app) | `cmux apps hide <id>` | app section header, app status item, App Store row, Settings > Apps row | exempt `personalViewPreference`: hiding is how the user arranges their own surfaces; an agent hiding apps would remove things from the user's view without a gesture |
| `app.unhide` | "Show Hidden Apps" (opens the sheet; always present, also when nothing is hidden) | `cmux apps unhide <id>` | Settings > Apps row, Show Hidden Apps sheet | exempt `personalViewPreference` |
| `app.enable` / `app.disable` | "Enable <App>" / "Disable <App>" | `cmux apps enable <id>`, `cmux apps disable <id>` | App Store row, Settings > Apps row | exempt `userOnlyStateChange`: turning an app off or on changes what runs for the user; agents ask the user |
| `app.set_hidden_access` | none (Settings > Apps > <app> > While Hidden) | `cmux apps hidden-access <id> [--cli on|off] [--mcp on|off] [--automations on|off]` | none | never: an agent could grant itself access to a hidden app |
| `app.remove` | "Remove <App>…" (confirmation for default installs) | `cmux apps remove <id> [--confirm]` | App Store row, Settings > Apps row | exempt `destructive`: removes storage and grant |
| `app.list` | none | `cmux apps list [--all] --json` | none | yes (read; `include_hidden` honored) |

Sidebar right-click for every app item and app section (sections lead builds the generic part): "Remove from Sidebar" / "Remove from Section" and "Hide <App>".

## 6. UI prototypes (CmuxNextAppPermissions)

- Installed Apps (`AppPermissionsSurface.installed`): Hide/Unhide, Disable/Enable, Remove (default installs: "Remove…" asks, with "Hide Instead"; team installs: Remove only for team admins, `AppInstallStateSource.isTeamAdmin`). The list is a projection: `AppInstallStateSource.observe` delivers owner events from every channel and device, applied only for a higher revision. Debug Settings `apps.installed.style` = `cards` (default, Lawrence's pick for store layouts) | `rows`.
- Show Hidden Apps sheet (`.hiddenApps`): every hidden app with Unhide and the channels that still run it.
- Permissions pane, "While Hidden": CLI, MCP and Automations switches and Hide/Unhide (`AppPermissionsModel.installs`).

## 7. Questions for the sections lead

1. How does an app section (and an app item inside a section) report its owning app id to the filter? Proposal: `LayoutSection.contribution` keeps `<app id>#<implementation id>` and the section provider exposes `owningApp`.
2. Where does the sidebar get the set of apps it may show? Proposal: the App passes the allowlist `AppPresenceFilter.presentApps(states)` (installed, enabled, not hidden; an app with no record is absent) into the section provider and the palette catalog builder from one observable source; no surface filters on its own.
3. Placeholder behavior: a hidden app's section keeps its layout record and renders nothing (no gap, no header). A disabled app's section: same, or a one-line "Disabled" placeholder with Enable? Proposal: same as hidden (nothing), with Enable only in Settings > Apps.
4. "Hide <App>" on a section header and "Remove from Section" on an app item: does your generic remove carry the app id so the menu can add "Hide <App>" from one placement (`appSectionHeader`, `appSectionItem`)?
5. After unhide, does the section reappear at its old position without a relayout animation from zero height (Reduce Motion respected)?

## 8. Decisions

- DECISION: an unconfirmed Remove of a default-installed app hides it in the owner (outcome `converted_to_hide`) instead of a reject. RECOMMEND: keep, because the CLI and every UI then share one rule and a user never loses a first-party app by accident.
- DECISION: the Installed Apps list in Settings shows hidden apps (dimmed, with Unhide). RECOMMEND: yes, because Settings is the management place; the "Installed" badges in the App Store follow the filter.
