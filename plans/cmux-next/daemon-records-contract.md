# The Mac daemons' records: chats, terminals and Cloud references

What the Rust daemons on the Mac store, who owns each record, how long it lives, and how the CLI
and the Mac app share one contract for it. Written for the Cloud meeting of 2026-11-06. Leo:

> "Rust daemon on Mac stores chats as ACP sessions, terminals, and references to active cloud
> VMs/cloud terminals."
>
> "Define a shared RPC contract used by both CLI and Mac app, including state ownership and
> lifecycle boundaries."
>
> "Specify durable local persistence vs recently-used cache vs authoritative remote resources,
> especially that references/cache do not by themselves own remote VMs/terminals."
>
> "Avoid a separate blocking startup wait for dependent components; they should naturally
> start/become available once the underlying ACP component is enabled."
>
> "Define CLI E2E workflows and test coverage for the agreed chats/ACP sessions, terminals, and
> cloud-resource-reference paths; validate the complete plumbing before Mac app integration."

It builds on [state-ownership.md](state-ownership.md) (one owner per fact; a cache is rebuilt
from the owner and never written back) and [OWNERSHIP-PRINCIPLES.md](OWNERSHIP-PRINCIPLES.md).
Where they disagree, those win. Each statement below names the code or spec that holds it today.
Where something is the target and not yet true, the statement says so, and [Gaps](#7-gaps) lists it.

## 1. Decided, and what is still syntax

Decided (the meeting, then Leo on 2026-11-07, cmuxterm-hq#7487):

- A chat is an ACP session in an acpmux. A terminal is a session-owned resource of a cmux-tui
  daemon. A Cloud VM, and every terminal and chat on it, belongs to the VM. The Mac holds only
  references to it.
- A reference or a cache never owns what it points to (section 3).
- `cmux chat` with no target is a chat here. One target flag picks another device, a VM or Cloud,
  and the target's value decides its kind. A target is checked against capabilities and sign-in
  at the time of the call, and a refused target starts nothing.
- There is no public `cmux vm chat`. `cmux cloud` is renamed `cmux vm`. `machine` is an old
  spelling of `device`.
- A dependent part starts when it is first used. It never waits on a startup gate (section 5).

Still syntax, and free to change without changing anything above:

- The flag's spelling and values. Today they are `--on here|cloud|vm|vm:new|vm:ID|NAME|DEVICE`,
  with `CMUX_ON` and `cmux config set on` (#37431, #37472, #37485; `cmux chat --help`).
- Whether `--on` reaches every verb (`exec`, `ssh`, `open`). That is cmuxterm-hq#7487's
  proposal, not built yet.
- What `cloud` will mean. Today it is the person's most recently used running chat VM (latest
  `last_active_at`, else `created_at`, in `cloud list-machines`; never one made for something
  else, such as a `lease-…`, probe or `cloud-devloop` machine, nor a teammate's when the list
  names the signed-in user), else a new VM, and never a question. The answer names its
  `placement` (`vm:ID`), so nothing depends on `cloud` meaning a VM.

The routing selectors (`here`, `cloud`, `vm`, `vm:new`) name a rule for picking a target. A device
id or a VM id names one concrete target. `resolve_chat_target` (`cmux-tui/bindings/rust`) and
`chat_start.rs` take a selector to a concrete target before anything starts, and the answer
carries the concrete target. A refusal is one of `chat_target.unknown_device`,
`ambiguous_device`, `unknown_vm`, `which_vm`, `vm_starting`, `not_permitted`, `unavailable`,
`signed_out` or `no_route`, and it says what to run next. `which_vm` and `vm_starting` are `vm`'s
alone: `cloud` picks a VM, or makes one, instead of asking.

## 2. What the Mac stores, and where

| Record | Owner on the Mac | Where | Kind |
| --- | --- | --- | --- |
| Chat (ACP session): its events, policy, queue | acpmux | `<ACPMUX_HOME>/sessions/<id>/session.json`, append-only `events/NNNNNN.ndjson`, `journal/` (`acpmux/README.md`, `store.rs`) | durable |
| Terminal, tab, pane, workspace, frontend projection | cmux-tui session daemon | SQLite under `~/Library/Application Support/cmux-tui/sessions` or `--state` (`spec/transports.md`), journal and checkpoints (`spec/session-journal.md`) | durable |
| Terminal output history | cmux-tui session daemon | the session's output files (`spec/session-journal.md`) | durable |
| A known remote daemon: fingerprint, key, route hints, last use | cmux-remote | `~/Library/Application Support/cmux/remote/known-daemons.json` (`cmux-remote/src/identity.rs`) | durable reference |
| A Cloud VM in the machine catalog | cmux-tui session daemon | memory only: the app publishes it (`machine-catalog-publish-v1`) and the connection record is its lease (`client_registry/machine_catalog.rs`) | lease |
| A Cloud VM's acpmux as a peer | acpmux | memory only: `_acpmux/peer_lease`, never in `config.json`, stops with its connection (`hub/peer_lease.rs`) | lease |
| A peer chat's last-seen events | acpmux | `<ACPMUX_HOME>/peer-snapshots/`, at most 2 MiB a session and 64 MiB in all, least recently used out (`acpmux/README.md`) | recently-used cache |
| A local workspace bound to a VM's workspace or tab | the app (Swift `CloudVMState.document`, `WorkspaceCloudVMBinding`) | the app's state (`docs/cloud-cmux-tui-daemon.md`) | durable reference, not yet in a Rust daemon (Gaps) |
| Warm connections to recently used machines | cmux-tui client | memory, 5 by default (`docs/machines.md`) | recently-used cache |

Leo's target puts the third kind of record, references to active Cloud VMs and Cloud terminals,
in the Rust daemon. Today the daemon holds VMs only as the app's lease-bound catalog projection,
and the durable binding lives in the Swift app. Moving it into the daemon is the first gap.

## 3. Three tiers: durable local, recently-used cache, authoritative remote

**Authoritative remote.** The cmux VM API (the backend's `cmux_vm` ownership rows and the
provider) owns whether a VM exists, runs, is paused or is deleted. The VM's own cmux-tui daemon
owns its terminals, and its own acpmux owns its chats. Their state is on the VM's durable disk
(`~/.local/state/cmux/remote`, `docs/cloud-cmux-tui-daemon.md`). Nothing on the Mac is a second
copy of these facts that could win over them.

**Durable local.** Facts whose owner is on this Mac: local chats (acpmux), local terminals and
layout (cmux-tui), the person's views, and the references in section 2. They survive an app quit,
a daemon restart and a reboot.

**Recently-used cache.** Bounded copies kept so a view paints at once: peer snapshots, the warm
connection pool, the sidebar snapshot file, the route hints. A cache is rebuilt from its owner
and dropped when its owner says the thing changed. Losing the whole cache loses no fact.

**The rule: a reference or a cache does not own a remote VM or terminal.** Holding, adding,
dropping or losing a reference, a lease, a catalog row or a cached copy never creates, wakes,
keeps alive, pauses, stops or deletes a VM, a terminal or a chat. Only an explicit request to the
owner does that, by public id: `cmux vm new|pause|resume|rm` to the VM API, `terminal.close` to
the VM's daemon, a chat's close to its acpmux. In the code today:

- A closed pane never destroys a remote resource (`docs/cloud-cmux-tui-daemon.md`, the surface
  catalog). Closing a tab, pane, workspace, projection or connection detaches views; only
  `terminal.close` ends a terminal (`spec/resource-api-v2.md`).
- The catalog projection grants no carrier or session authority, and removing it removes only
  the projection (`machine_catalog.rs`, `spec/resource-api-v2.md`).
- A leased peer ends with its connection and leaves nothing on disk (`peer_lease.rs`). The peer
  snapshot "is never a write lease or an execution checkpoint" (`acpmux/README.md`).
- cmux-tui "does not create, destroy, snapshot, or authorize VMs" (`spec/remote-daemon.md`).
- Quitting the app keeps sessions running (`quit-persistence.md`). It detaches the Cloud broker
  and stops no machine (`CloudService.swift`).
- Cloud-owned terminals live in the VM daemon's session, or detached, and never on a
  connection-scoped lease (`docs/cloud-cmux-tui-daemon.md`).
- The backend, not the Mac, deletes a VM that no ownership row records (the orphan sweep,
  `workers/cmux-vm/src/upstream/orphan-sweep.ts`).

The other direction holds too: a remote resource that goes away is not an error in the
reference. The reference reads as gone, unavailable or paused, and the view says so. It is
dropped only when its owner says the resource was deleted.

## 4. One contract for the CLI and the Mac app

- **The public contract is `cmux.protocol/2`** (`cmux-tui/spec/README.md`, operations in
  `spec/resource-operations-v2.json`). The CLI, the SDKs (`cmux-tui/bindings/`) and the app's
  calls into a session daemon all use it. The private mux protocol v12 is a frontend transport (rendering and attach).
  The target is that it carries no fact the public contract lacks. The app reaches the same socket the
  CLI dials (`app-daemon-connection-DESIGN.md`). The Rust SDK's daemon client is the shared
  implementation: `cmux-sdk-ffi` exposes it as a C ABI and `cmux-app-ffi` links it (#37370), so a
  rule such as `resolve_chat_target` is written once.
- **An endpoint executes on exactly one local session.** A machine or session handle only routes
  to its owner. Cross-machine work goes to the target's own daemon over a carrier, or to the VM
  API. It is never aggregated into a second owner (`spec/resource-api-v2.md`).
- **Ownership** is section 2's table: one owner per record. A client (the CLI, the app, an agent
  or a phone) caches only and writes to the owner, by public id, with an idempotency key.
- **Lifecycle boundaries.** What each event ends, and what it never ends:

| Event | Ends | Never ends |
| --- | --- | --- |
| A CLI command exits, or a client connection drops | its own stream, its `workspace`-lifetime processes, the leases it held (catalog projection, leased peer) | a terminal, a chat, a VM |
| A pane, tab or workspace closes | its views | the terminal (only `terminal.close`), the chat, the VM |
| The app quits | the app's leases and its broker | acpmux (it exits about 2 s later unless an agent or a turn holds it, `owner_exit.rs`), the session daemon, terminals, chats, VMs |
| The session daemon restarts | its processes (clients see the generation change) | durable layout and journal, chats in acpmux, VMs |
| A VM pauses or is deleted by its owner | that VM's terminals and chats, there | local records: references read as paused or gone |

## 5. Startup: no separate wait

A part that depends on acpmux or on the session daemon starts that component on first use, then
goes on. Nothing waits for it at boot, and no component holds its start until another one
reports ready.

- The session daemon starts acpmux only when an `agent-session-start` finds none on its socket
  (`AcpmuxStarter`, `cmux-tui/src/acp.rs`, `agent_session_start.rs`). An inventory refresh never
  starts it (`agent_inventory_refresh_tests.rs`).
- The app's agent pane starts acpmux in `AgentPaneHost.findOrStart`. A reconnect never starts or
  stops a daemon (`AgentPaneHost.swift`).
- `cmux acp` and `acpmux` start the daemon when it is not running (`cmux-tui/crates/acpmux/docs/cli-daemon.md`).
- A Cloud VM's snapshot is taken with cmux-host and acpmux already running, so a new VM resumes
  with them up (#37440, `snapshotReadyCommand` in `web/scripts/cmux-vm-image/bake.ts`).
- The waits that remain are bounded waits inside one component's own start: acpmux's readiness
  line, and `server ensure` waiting for a restoring owner (at most 150 s). The first window
  paints from the sidebar snapshot file instead of waiting for the daemon.

A new dependent follows the same pattern. It calls the component, which starts if needed, and
the call bounds its own wait. It does not add a startup wait of its own.

## 6. CLI E2E workflows and their coverage

The plumbing is proven from the CLI before the Mac app is integrated. Each workflow lists the
test that proves it today.

| # | Workflow | Proven by | Runs |
| --- | --- | --- | --- |
| W1 | `cmux chat 'PROMPT' --wait`: a chat here, its reply, `chat send`, `chat read`, a restored chat | `tests/cli/agents_chat_tools.rs` (real daemon, real acpmux, `fake_agent.py`): `an_agent_starts_a_chat_in_a_workspace_and_drives_it_without_the_app`, `a_caller_sends_to_a_restored_chat_no_tab_has_shown`, `cmux_chat_here_checks_its_files_before_it_starts_a_chat` | `cmux-tui-spec.yml` on every PR |
| W2 | Two callers, one acpmux: a caller with its own acpmux drives the app's | `a_caller_with_its_own_acpmux_starts_and_drives_a_chat_of_the_apps_acpmux` | same |
| W3 | Terminals outlive their clients: daemon and holder SIGKILL, `server ensure` convergence | `tests/holder_terminals.rs`, `tests/detached_owner.rs` | same |
| W4 | `--on` parsing and target refusals | `src/cli/chat_start/tests.rs`, the SDK's `resolve_chat_target` tests | same |
| W5 | A Cloud VM from the CLI: create, exec, agent start, chat turns, daemon restart, carrier dial, pause, resume, delete | `scripts/cmux-next/cloud-journey.ts` | `cloud-journey-pr.yml` (staging, on Cloud CLI paths), `cloud-journey-prod.yml` (hourly) |
| W6 | A Mac-shaped daemon and a VM-shaped daemon: move and bring back | `tests/cloud_move_journey.rs`, `tests/bring_back_journey.rs` | `cmux-tui-spec.yml` |
| W7 | `cmux chat --on vm:new --wait` through the app | `cloud-chat-proof.yml` (a tagged DEV app) | manual |
| W8 | A leased peer ends with its connection | unit tests in `acpmux/src/hub/peer_lease.rs` | `cmux-tui-spec.yml` |

## 7. Gaps

Each gap is a handoff in cmuxterm-hq#8366. None is built here.

1. **Cloud references in the Rust daemon.** The durable workspace-to-VM binding lives in the Swift
   app (`CloudVMState`), and the daemon holds VMs only as a lease. Target: the session daemon
   stores references to active VMs and Cloud terminals as durable records, with section 3's rule,
   and the app reads them as a client.
2. **`cmux chat --on vm:` without the app.** It runs the app-backed `cloud start-chat` path. No
   test or workflow runs it CLI-only against a VM, so W7 is manual.
3. **The rule in section 3 has no end-to-end test.** No test drops a catalog entry, a leased peer
   or a cached copy and then checks that the VM, its terminals and its chats are untouched. None
   quits the app, or restarts the daemon, and then checks the VM still runs.
4. **Session startup is undocumented** in `spec/programmability.md`: socket resolution, ownership
   and auto-start. Section 5 is the behaviour, and it belongs in that spec.
