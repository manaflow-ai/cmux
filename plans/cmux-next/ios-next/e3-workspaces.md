# E3 `workspace-mgmt`: groups, reorder, customize and SSH workspaces

Status: lane E3 of PLAN.md wave E, 2026-10-07. Branch `feat-cmux-next-ios-e3-workspaces` off
`feat-cmux-next-ios`. Closes d3-dogfood.md parity rows 1.8 "Groups: collapse, rename, drag reorder
across groups", "Customize sheet (color, icon)" and "SSH computers and their workspaces in the
list". Binding: PLAN.md section 4, OWNERSHIP-PRINCIPLES.md, c5-workspaces.md (mirror, intent log,
`WorkspaceHostKind.ssh`), b5-mac-host.md section 3 (policy), c9-ssh.md (connections, trust,
`SSHTerminalByteSource`), a2-ghostty.md (`TerminalByteSource`).

## 1. Ownership

| State | Owner | On the phone |
| --- | --- | --- |
| Workspace order, group membership, group names, workspace color and icon | the Mac's workspace store (personal groups and order on the home session, `workspace.place`, `workspace_group.update`; color and icon via `set-workspace-metadata`) | mirror + intent log (C5) |
| Which group sections are collapsed on this phone | this client (view state, `WorkspaceViewPreferences.collapsedGroups`, never synced) | `UserDefaults` |
| tmux sessions and windows, screen sessions, cmux-tui sessions on an SSH host | the SSH host (its tmux server, screen, cmux-tui owner) | a read-only projection rebuilt by discovery; no intents |
| Which SSH targets were discovered | the discovery run (phone, ephemeral) | `SSHSessionCatalog`, the only source an attach may use |

Group collapse is client view state on purpose: the Mac's own shared `collapsed` flag would make
the Mac sidebar jump while someone glances at the phone (sidebar-sections.md section 5 keeps
section collapse per window for the same reason).

## 2. Daemon capabilities (checked first)

`plans/cmux-next/daemon-capabilities.json` lists `workspace-groups-v1`, `workspace-metadata-v1`,
`profiles-v1` and `personal-mixed-order-v1`. The Mac app files workspaces in personal groups on the
home session (`WorkspaceGroupHandlers`: `workspace.place {workspace, group, index}`,
`workspace_group.update {name}` through `StateResourceClient`), colors through
`set-workspace-metadata {color}` (palette tokens `grey blue red yellow green pink purple cyan
orange`) and icons through the same command (`icon`, an SF Symbol name). No new daemon op is
needed; the phone ops map one to one onto those.

## 3. Wire additions (A0, additive, catalog + schemas + fixtures + Swift + TS in one commit)

- op `workspace.move {workspace, group?, index}`: `group` absent keeps the workspace's group,
  `null` ungroups, a string files it in that group; `index` is the final position among the
  destination section's other members (the daemon's `move-workspace-to-group` rule), clamped.
  Errors `workspace.not_found`, `workspace.group_not_found`. Cap `workspace.move`.
- op `workspace.group.rename {group, name}`. Errors `workspace.group_not_found`. Cap
  `workspace.group.rename`.
- op `workspace.customize {workspace, color?, icon?}`: absent unchanged, `null` clears; color is a
  palette token `[a-z][a-z0-9-]{0,31}` or `#RRGGBB`, icon an SF Symbol name `[a-z0-9.]{1,128}`.
  Name changes keep using `workspace.rename`. Errors `workspace.not_found`. Cap
  `workspace.customize`.
- owner event `workspace.groups.set {groups}`: the host's ordered groups, so an empty group can be
  a drop target and a rename of an empty group still reaches the phone.
- optional fields: `Workspace.icon`, `Workspace.group.order`, `workspace:state.groups`
  (`[{id, name, order}]`); `Workspace.color` also accepts a palette token (the Mac already sends
  tokens).

## 4. Mac side (CmuxMobileHost and the CmuxNext adapter)

`MobileOpPolicy` allows the three ops under the B5 rules: only the listed params, command-bearing
params refused with `auth.forbidden`, `ws_` ids resolved in this host's tree, group ids resolved
in the tree's groups, values checked against the patterns above. New `MobileDaemonOp` cases
`moveWorkspace`, `renameGroup`, `customizeWorkspace`. `MobileWorkspace` carries `icon` and
`group {id, name, order}`, `MobileWorkspaceState` carries `groups`; `WorkspaceDiff` emits
`workspace.groups.set` when the groups change. Default caps add the three caps.

The adapter (`CmuxNextMobileLink`) projects personal groups and order from `list-personal` when the
daemon serves `profiles-v1` (shared `Tree.groups` otherwise), and performs: move through
`workspace.place` (section index converted to the personal order index), rename through
`workspace_group.update`, customize through `set-workspace-metadata`.

## 5. Phone: Workspaces list

- FeatureKit: intents `move`, `renameGroup`, `customize`; caps `.move`, `.renameGroup`,
  `.customize`; `WorkspaceSummary.icon`; `WorkspaceGroup.order`; `HostWorkspaces.groups`.
- Core: wire decode of the new fields and `workspace.groups.set`; encoder; intent log overlays
  (move renumbers the host order and refiles the group, group rename renames every member and the
  group record, customize sets color/icon); `WorkspaceReorder` (pure) turns a drop (row, target
  section, index) into a `move` intent or nil; list builder: group sections carry their group id,
  collapsed groups list no rows, empty groups appear only while reordering is possible.
- UI (UIKit list): Edit button turns on reordering (`.reorder` accessories, diffable
  `reorderingHandlers`), allowed only in machine grouping, owner order, no filter, on a reachable
  host with `.move`, never across machines or into Pinned; the drop becomes one intent with a
  fresh `IntentKey` and the overlay keeps the row where it landed until the echo. Group headers
  toggle collapse on tap and offer Rename Group. Rows add Customize… (sheet: name, color, icon)
  and Move to Group.

## 6. SSH workspaces

- `CmuxiOSSSHCore`: `SSHSessionTarget` (`tmux` session or window, `screen`, `cmuxTUI`) with ids
  validated against `[A-Za-z0-9_.:-]+` (screen `<pid>.<name>`, tmux window index digits), and
  binary paths validated as absolute plain paths; `SSHSessionDiscovery` (one exec of `/bin/sh -s` with the script on stdin: locate tmux,
  `tmux list-sessions -F`, `tmux list-windows -a -F`, `screen -ls`, locate `cmux-tui` and list its
  session sockets) with a pure parser; `SSHChainDialer` shared by the shell connector, the new
  `SSHAttachConnector` (PTY + `exec <tmux> attach-session -t <id>`, `screen -x <id>`,
  `<cmux-tui> attach --socket <path>`) and `SSHCommandRunner`. cmux-tui keeps the first valid
  named socket in runtime-directory order, validates its absolute path through `SSHCmuxTUISocket`,
  and attaches to that exact owner. The `attach` verb fails if the owner has exited; it cannot
  start a replacement session or derive a different socket from the SSH login's environment.
  No free text reaches a command: the target comes only from `SSHSessionCatalog`, which holds
  what discovery returned.
- `CmuxiOSSSHWorkspacesCore` (new): `SSHHostDirectory` (SSH records of the `HostsStore` as `.ssh`
  descriptors), `SSHWorkspaceChannel` (a `WorkspaceControlChannel` whose snapshot is discovery
  projected to the workspace state: tmux session = workspace, window = terminal tab; screen and
  cmux-tui session = workspace with one terminal tab), `RoutingWorkspaceChannelFactory` (`.ssh`
  to SSH, the rest to the control plane) and `SSHWorkspaceTerminalSourceFactory`. Discovery runs
  when the channel opens, on `requestSnapshot()`, and when an attached SSH terminal closes; never
  on a timer. It uses a non-interactive host key check: an unknown or changed key or a host
  without a login shows the host offline with the reason, so the list never pops a trust prompt.
  SSH hosts get no workspace intents (empty caps).

## 7. Tests (Swift Testing)

CmuxMobileWire catalog and fixtures; CmuxMobileHost policy (scope, params, values, command
params), executor end to end, diff of groups; WorkspacesCore mirror (`groups.set`, icon), encoder,
overlays, reorder resolver, list builder (collapsed, group ids, empty groups); SSHCore target
validation, discovery parser, attach command quoting; SSH workspaces channel over a fake runner,
directory mapping, terminal factory refusing unknown targets.

## 8. Not here

Creating and deleting groups and group colors from the phone, moving a workspace to another Mac,
SSH session create/kill/rename, tmux control mode (one terminal per window through `attach`),
discovery for hidden machines being skipped, live verification on a device (tagged builds are
blocked on this Mac).

## 9. Status (2026-10-07)

Done: wire (catalog, schemas, fixtures, Swift, TS; CmuxMobileWire 24 tests, workspace fixtures
validated with the TS subset validator run directly, vitest not run: no `node_modules`);
CmuxMobileHost policy, daemon ops, groups in state and diff (152 tests); the CmuxNext adapter
(projection tests pass in a scratch package that compiles CmuxNextDaemon in Swift 5 mode, because
this toolchain rejects an existing `DaemonStore+Driver` sendability check); FeatureKit,
WorkspacesCore, SSHCore discovery and the new CmuxiOSSSHWorkspacesCore with Swift Testing (137 tests
across FeatureKit, WorkspacesCore, SSHCore and SSH workspaces pass on macOS through a scratch
package); the Workspaces UI and composition. CmuxiOSApp compiles for
`arm64-apple-ios17.0-simulator` with SwiftPM.

Unverified: everything visual (no simulator run: reorder drag feel, header taps, the customize
sheet, VoiceOver), live SSH discovery and attach against real tmux/screen/cmux-tui hosts, the Mac
adapter against a live home daemon (`workspace.place` index conversion, personal groups), and the
`list-personal` cost per tree change. A review subagent's findings (Home in the placement index,
the move-workspace fallback index, cross-section drop detection, overlapping discovery runs, csh
login shells) are fixed. Tagged build not attempted (lane rules: no tagged builds on
this Mac).

### SSH socket attachment follow-up (2026-10-07)

`SSHCmuxTUIAttachTests` covers non-default runtime directories, duplicate-name precedence,
invalid socket paths, and quoted directory names. `SSHWorkspacesTests` covers attachment using
an updated catalog socket and refusal after the session disappears. Runtime Swift execution
and a live stale-owner SSH check remain unverified: `nx-remote status` fails because this Mac
cannot resolve `cmux-lawrence-2`. Swift syntax and scoped conventions checks are static evidence
only. The existing connectivity soak uses Iroh and does not cover this SSH discovery/attach path;
it needs a separate named-socket SSH workload before this change can claim live coverage.

### tmux control attachment follow-up (2026-10-07)

Modern tmux rows now carry host-issued server/session/window identities instead of attaching by
name and window index. Rename and reindex preserve identity; server replacement expires it. The
catalog remains the only attachment source. Control-mode events request rediscovery on layout,
window/session lifecycle and name changes, in addition to the existing terminal-end trigger.
`NIOSSHShellConnector` uses no PTY, verifies the server epoch, requests the selected window's size,
and exposes bounded snapshot-then-live bytes and hex-only input. It never selects a shared active
window, creates a session, or silently attaches to a different pane. Invalid modern discovery
records cannot downgrade to the legacy attach command.

See `c9-ssh.md` for bounds, protocol references, and the added Swift tests. Static checks pass;
native test execution and live SSH/GUI verification remain unverified. The current implementation
supports one pane per window with a matching host-confirmed viewport; multi-pane/window geometry,
history and complete parser-state restoration remain parity gaps. No D3 row is promoted by this
source-only verification. Lifecycle mutations remain deferred until owner idempotency exists.

### Host split geometry discovery (2026-10-07)

Modern discovery now reads `L2` window-layout rows alongside `W2` windows and `P2` panes. A bounded
`SSHTmuxLayout` parser supplies the read-only split tree and cell frames on each discovered window;
its checksum, exact geometry, unique ids, and pane inventory must agree before geometry is exposed.
Malformed or conflicting layout rows clear that metadata, while attachment continues to use the
existing validated server/session/window/active-pane target. Stable workspace/surface ids are
unchanged. No SSH create, rename, kill, pane selection, or renderer layout mutation is introduced.

The C9 layout tests include discovery regressions for mismatched pane inventories and repeated or
conflicting rows. Syntax/convention/concurrency/crash-safety checks passed; native Swift test execution
and live SSH remain unverified because the dedicated build host cannot resolve. This model does not
promote the multi-pane rendering parity row. See `c9-ssh.md` for bounds and protocol references.
