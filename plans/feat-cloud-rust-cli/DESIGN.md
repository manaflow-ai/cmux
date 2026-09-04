# Rust Cloud client and CLI: implementation plan

Status: proposed execution plan. This plan implements the
[canonical Cloud Rust system design](../../docs/cloud-rust-system-design.md).
It is intentionally vertical. Every slice must be useful to an agent before
the next slice expands the command surface.

## Scope and success condition

Move Cloud control-plane behavior out of the Swift CLI while preserving names
during migration. Rust must work from a clean npm or PyPI install without the
desktop app. The desktop remains a projection, local OS integration, and
human-approval client.

The first release is complete only when this path works with a receipt:

~~~text
auth login
→ team use
→ cloud vm list
→ cloud vm create
→ cloud vm exec or ssh
→ cloud session attach
→ cloud agent run through CodeRouter
→ cloud domains verify example.com
→ cloud domains publish <vm> 3000 --domain app.example.com --access team
→ verify the published URL and access policy
→ disconnect and resume
→ snapshot
→ cloud vm destroy
~~~

A parser, help screen, Swift subprocess wrapper, or headless daemon without
this path is not a release.

The implementation must preserve this authority flow: create a ready VM and
leased workspace, launch Claude with a model-only route, run the normal cmux
viewer and topology verbs against the VM daemon, mirror events into one local
Cloud workspace, and reconnect without changing resource IDs. A failed host
attachment never changes the guest target or falls back to the local socket.

The clean-install test uses a generated cmux.sh hostname. A separate live
domain smoke must run the customer-zone DNS checklist, repeat verify after the
DNS change, wait for wildcard certificate readiness, exercise protected and
public access, and unpublish. This makes custom-domain support a release
requirement without making package tests depend on a user's DNS service.

## Fixed architectural decisions

1. `cloud <resource> <action>` is the canonical public grammar. `vm` and the
   established `vm agent` and `vm domains` spellings resolve to canonical
   cloud actions and preserve existing scripts.
2. Rust owns wire models, authentication, team context, Cloud API behavior,
   errors, retries, operations, and command semantics.
3. Swift calls the same Rust contract during migration. It does not retain a
   second Cloud implementation.
4. Backend services own managed-edge integration, DNS, TLS, billing, policy,
   and secret custody.
5. cmux-remote owns live terminal, workspace, process, and event transport.
6. Every mutation has an idempotency key and every long mutation has an
   operation receipt.
7. JSON and JSONL are first-class output contracts. Human output is a
   projection of the same result.
8. Team and profile selection are explicit. A command never changes context
   because a previous response happened to mention another team.
9. System VPN, userspace WireGuard, private port access, and public domains
   are separate paths.
10. Guest images never contain user, infrastructure, DNS, or CodeRouter bearer
    credentials.
11. Behavior and artifact tests prove the contract. Source-shape tests do not.
12. Public custom-domain publication is in the first Cloud release. Verified
    zones, TLS, access policy, health state, and cleanup are required together.
13. The shipped cloud domains rm hostname flow remains one command with its
    existing aliases and output. Rust adds backend ownership, revision,
    idempotency, and cleanup fences without adding a prompt.
14. Rust owns network policy and userspace WireGuard. Small native adapters
    may call NetworkExtension and platform keyrings, but they cannot own
    Cloud behavior or policy.
15. Machine creation claims a scrubbed warm machine first. The warm path targets
    p50 under 3 seconds and p95 under 10 seconds to daemon readiness. `cloud vm
    create` waits for readiness by default; a cold path returns an operation
    immediately and the Rust client follows it with progress and a bounded
    deadline. `--no-wait` opts into asynchronous control.
16. Action checks are automatic. There is no required capabilities command;
    `--help --json` describes one action and unsupported actions return a typed
    replacement or upgrade hint.
17. A public `coderouter-core` contract, generated Rust protocol, async client,
    and secure handoff library are shared by standalone `coderouter` and
    `cmux coderouter`. Command, TTY, keyring, config, and process frontends
    remain separate.
18. A Cloud VM owns only its resources inside an explicit machine, session, and
    workspace lease. The Mac projects those VM resources into a dedicated local
    Cloud workspace. A remote agent cannot request a host file, host browser,
    host path, or host socket. Local-file sharing is a separate user-only flow
    with a short-lived, bounded copy.

## Ownership and dependency graph

| Workstream | Primary paths | Depends on |
| --- | --- | --- |
| Cloud contract | cmux-tui/crates/cmux-cloud-protocol, schema fixtures | none |
| CodeRouter contract | public coderouter-core schema and generated artifacts | none |
| Cloud API client | cmux-tui/crates/cmux-cloud-client | Cloud contract, auth |
| CodeRouter client | public coderouter-core async client | CodeRouter contract, auth traits |
| Secure agent handoff | public coderouter-core handoff library | CodeRouter contract |
| CLI frontend | cmux-tui/src/cli/cloud and command dispatch | Contract, client |
| Remote data plane | cmux-remote, cmux-terminal-client | Contract, enrollment |
| Remote topology and projection bridge | VM resource broker, local placement adapter, and native viewer adapters | Auth, remote session, workspace lease, local approval policy |
| Private network | cmux-wg and Swift NetworkExtension bridge | Auth, grants, route API |
| Backend facade | web/app/api, web/services/vms, CodeRouter services | Contract fixtures |
| Guest runtime | image manifest, daemon supervisor, adapters | Action checks, machine principal |
| Desktop bridge | Sources/Cloud and Swift CLI compatibility files | Rust client, generated models |
| Distribution | cmux-tui/dist, package_npm.py, PyPI workflow, app bundle | Protocol manifest |
| Verification | Rust tests, web tests, hosted E2E, clean-install jobs | Each slice |

The implementation order is:

~~~text
C0 schema and errors
→ C1 auth, profiles, teams
→ C2 HTTP client and bounded action checks
→ C3 fast machine catalog and operations
→ C4 create, base, snapshot, fork, restore
→ C5 remote sessions, terminal, exec, transfer
→ C5a scoped remote topology and projection boundary
→ C6 VPN, private routes, ports, domains
→ C7 project environments and layouts
→ C8 agents and CodeRouter
→ C9 events, notifications, desktop, mobile
→ C10 Swift migration and removal
→ C11 package and release hardening
~~~

A slice is not complete until its backend mapping, Rust command, compatibility
bridge, focused behavior tests, and clean-package or hosted acceptance path
are present.

## Existing backend migration map

The first client implementation wraps these existing routes behind the
versioned facade. The map is a migration aid, not permission to expose route
names as the public CLI:

| Rust resource or action | Current compatibility surface | Required Rust contract |
| --- | --- | --- |
| auth and profiles | vault CLI auth start, poll, approve; CLI config | device flow, refresh rotation, profile and team context |
| machine catalog and lifecycle | vm list, create, status, stats, leases, wake | stable machine model, operation receipt, readiness and reconciliation |
| base, snapshot, fork, restore | vm base, snapshot, fork, restore routes | generation and action fences, dependent-resource receipt |
| exec and ports | vm exec and open-port routes | exact argv, bounded output, bind probe, typed endpoint |
| remote enrollment and sessions | attach-endpoint, cmux-remote approve, sessions | grants, daemon generation, cursors, replay and snapshot recovery |
| project and routing | vm route, project and environment services | work key, manifest, plan, sync receipt, pool policy |
| domains and publications | vm domains and publications routes | the exact cloud domains verbs and Ben Swerdlow flow |
| CodeRouter | coderouter session, Claude upstream, VM usage routes | model-plane session, account policy, route authority, usage attribution |
| events and notifications | daemon event lanes and Cloud notification services | durable cursor, acknowledgement, gap recovery |

For each row, add a fixture that exercises the current route and the new
facade against the same state. Delete a compatibility route only after the
Rust client and Swift bridge use the facade and the hosted check covers the
same behavior. A route-by-route rewrite without shared fixtures is a lazy
migration because it can preserve names while changing authorization or
cleanup semantics.

## C0. Freeze the contract first

Create the Cloud contract and CodeRouter contract as pure, versioned artifacts.
The Cloud contract lives in `cmux-cloud-protocol`; the model-plane contract
lives in the public `coderouter-core` repository. Neither artifact performs
I/O. `cmux-cloud-protocol` must contain:

- generated request and response models;
- stable resource IDs and revisions;
- action preconditions and protocol versions;
- operation states and receipts;
- normalized error codes and retry classes;
- selectors, pagination cursors, event cursors, and verification receipts;
- redaction and secret-bearing field annotations.

Add checked-in JSON fixtures for auth, team, machine, workspace, terminal,
process, agent run, snapshot, network, port, domain, operation, event,
notification, and every error family. Generate Rust and TypeScript models from
one schema source. Add matching CodeRouter fixtures for account, route,
session, usage, handoff, and model actions. Add a conformance test that rejects
undocumented fields,
missing required fields, incompatible enum changes, and unredacted secrets.

Publish the model-plane schema, generated Rust protocol, TypeScript package, and
client crate as public, credential-free artifacts. Standalone CodeRouter and
cmux consume released versions. A private product repository must never be a
Cargo dependency of the public cmux build.

Define the CLI frontend around a typed CommandContext and resource modules.
The dispatcher resolves aliases and selects a module; it does not contain
infrastructure or resource behavior. CommandContext injects profile, team, clock,
cancellation, transport, and renderer. Generated action metadata supplies
action preconditions and option information, while reviewed handwritten projections keep
human UX, especially the existing domain flow, legible.

Expert review question: would an API owner accept these fixtures as the
versioned contract? If not, stop and fix the schema before adding commands.
A generic serde model without fixture ownership is a lazy choice because it
moves incompatibility detection to production.

Acceptance:

- Rust and TypeScript generation is deterministic.
- Every response has request and trace IDs where applicable.
- Unknown additive fields are tolerated; breaking changes require a version
  or compatibility record.
- Error codes map transport, auth, rate limit, conflict, unsupported action,
  backend, and indeterminate-effect failures.
- Public Cloud docs and generated help pass the deployment-neutral vocabulary
  check; implementation-only identifiers are not emitted.

## C1. Auth, profiles, and team context

Implement an injected AuthStore and platform stores:

- macOS Keychain;
- Linux Secret Service or explicit encrypted mode-0600 fallback;
- Windows Credential Manager or explicit restricted fallback;
- memory-only stdin mode for CI and one-shot jobs.

Implement device/browser login through the existing CLI auth routes, refresh
rotation, logout, expiry reporting, reuse detection, and cancellation.
Persist profile name, account ID, team ID, API origin, and device identity.
Never persist infrastructure secrets in a profile.

Commands:

~~~text
cmux auth login|status|logout
cmux team list|current|use <team>
cmux config profile list|use|show
~~~

The Swift CLI bridge must call these typed operations and render compatible
human output. Add tests for missing profile, expired access token, refresh
reuse, account mismatch, team ambiguity, and token redaction.

Expert review question: can a stolen VM or process snapshot obtain a user's
refresh token? If yes, the design is rejected. Plaintext token files,
environment snapshots, and token argv support are not acceptable convenience
features.

Acceptance:

- Login works with no desktop app and no existing socket.
- A command prints the selected team and fails when a team-only action has no
  selection.
- Logout removes local refresh state and invalidates the server session.
- CI can use stdin without writing credentials to disk.

## C2. API transport and action checks

Implement cmux-cloud-client with explicit dependency injection for clock,
HTTP transport, AuthStore, profile, and event sink. It owns:

- API origin and version negotiation;
- absolute request deadlines;
- bounded response bodies;
- typed pagination;
- refresh-once authentication;
- retry classification;
- idempotency headers for mutations;
- request and trace IDs;
- redacted diagnostics;
- bounded protocol, identity, authorization, and action checks;
- `--help --json` metadata for one command, with no catalog round-trip.

Do not add generic automatic retries for mutations. Retry only when the server
declares the effect unobserved or the same idempotency key makes the request
safe. Preserve the original deadline across auth refresh and managed-edge
phases. An unsupported action returns `action_unsupported` with the required
upgrade or a valid replacement. `cloud doctor` is an exceptional diagnostic,
not part of the normal create or attach path.

When `--idempotency-key` is absent, Rust generates one before network work and
includes it in the operation receipt. A local deadline returns the operation
ID and key without canceling backend work; the receipt points to
`cloud operation wait`. Cancellation is explicit and separately recorded.

Expert review question: can a timeout create two machines or two publications?
If the answer depends on a caller remembering a flag, the client is unsafe.
Idempotency and reconciliation belong in the client and server contract.

Acceptance:

- Fixture tests cover every retry class and deadline phase.
- Action mismatch returns a stable error with an available fallback or upgrade.
- Logs contain request and trace IDs but no tokens, terminal bytes, or URLs
  that carry credentials.
- A timed-out mutation returns enough operation and idempotency data to resume
  safely without issuing a second mutation.

## C3. Fast machine catalog and operations

Implement:

~~~text
cmux cloud vm list|get|status|stats|wait|wake|sleep|rename|destroy
cmux cloud vm create [--no-wait] [--timeout <seconds>] [--detach]
cmux cloud operation get|wait|watch|cancel
~~~

Support filters for team, project, state, image family, pool, and freshness. A
display name is never an identity. Ambiguous names return all candidate IDs.
Include image, daemon, route, billing, and action-specific state in machine
detail.

Machine creation first claims a scrubbed warm machine matching region, size,
image family, and persistence profile. The claim resets daemon state, binds a
new machine ID, attaches a clean encrypted home volume when persistence is
requested, and waits for one daemon-ready probe before returning. Target p50 is
under 3 seconds and p95 is under 10 seconds. If no healthy warm machine is
available, the backend starts the cold path and returns an operation without
blocking the request. The Rust client follows that operation by default, so
`cloud vm create` still returns a ready machine. `--no-wait` returns the
operation for asynchronous callers. `--timeout` bounds the default ten-minute
follow. `--detach` keeps the ready receipt headless and suppresses local pane
projection; it does not change the wait or machine lifecycle. A display name is
part of the create mutation, so a second rename call is not on the fast path.
No separate action-definition call is allowed on this hot path.

Warm-pool refill runs asynchronously. The claim transaction locks one slot and
invalidates stale leases, so concurrent creates receive distinct slots or take
the cold-operation path. Refill scrubs a slot before it becomes claimable and
never delays a ready receipt.

Wake, sleep, restore, publication, and destroy return operations when backend
work can outlive a request. Implement progress, poll-after hints, cancellation
tombstones, stale-create reconciliation, and late-callback protection. A wait
command proves daemon readiness and requested action preconditions, not only that
a machine record exists.

Expert review question: can a killed client recover the truth about a create?
If not, operation lookup by idempotency key and reconciliation are incomplete.

Acceptance:

- Repeated list and wait calls are bounded and cancellable.
- A canceled or stale create leaves no unowned backend resource.
- Sleep and wake preserve stable machine ID and report changed action state.
- Concurrent warm claims cannot return one slot to two callers, and refill is
  never required for the hot-path receipt.
- A cold create returns a usable ready machine by default, or a durable
  operation with `--no-wait`; a killed client can recover that operation by its
  idempotency key.
- Destroy requires explicit confirmation and cleans dependent resources.

## C4. Bases, snapshots, forks, and restore

Implement:

~~~text
cmux cloud vm base open|reset
cmux cloud vm snapshot list|create|get|delete
cmux cloud vm fork <snapshot>
cmux cloud vm restore <snapshot> <machine>
~~~

Define the difference between the persistent base machine, immutable
snapshots, and a forked machine. Include source generation, image digest,
daemon version, workspace metadata, publication dependencies, and retention.
Freeze or drain sessions and publications before restore. Return a receipt
that states what survives and what is intentionally discarded.

Use action checks before a backend call. Restore and delete are
idempotent, revision-fenced, and reconciled after timeouts.

Expert review question: does the command promise process continuity that the
daemon cannot prove? If yes, change the contract to durable exit/interruption
receipts. A snapshot label that hides process semantics is misleading.

Acceptance:

- Snapshot, fork, and restore work from JSON and human output.
- Image or daemon incompatibility is reported before destructive work.
- Retried restore does not create duplicate machines.
- Dependent sessions and domains have explicit outcomes.

## C5. Remote sessions, terminal control, and file execution

Use cmux-remote for live data. Implement:

~~~text
cmux cloud vm route|ssh|shell|exec|run|push|pull
cmux cloud session list|create|get|attach|detach|resume|close|events
cmux cloud workspace list|create|get|rename|close|delete
cmux cloud workspace layout export|apply
cmux cloud terminal list|get|send|read|wait|resize|signal|close
cmux cloud process list|get|wait|events|cancel
cmux cloud projection list|attach|move|detach
cmux cloud vm repo clone
~~~

Keep contracts separate:

- ssh is an interactive shell over cmux-remote, with OpenSSH only as an
  explicit fallback;
- exec runs one exact argv array with bounded stdout, stderr, exit code, and
  deadline;
- run chooses a machine by project or work key, optionally syncs, and returns
  the remote exit status;
- terminal commands drive an existing PTY and never create a pane or take
  focus;
- push and pull are resumable, digest-verified transfers;
- repo clone keeps large repositories and credentials in the VM.

Implement enrollment, peer grants, persistent identity, transport negotiation,
lane cursors, snapshots, replay gaps, bounded queues, and reconnect. A replay
gap must produce a typed error followed by a fresh snapshot path, never a
replacement shell hidden from the caller.

Expert review question: does ssh become a stringly typed shell workaround?
If yes, split the protocol. Structured process and terminal records are
needed for agent continuation.

Acceptance:

- A dropped link resumes the same session or returns a typed replay gap.
- Interactive input, resize, signal, and close are independently testable.
- Exact argv survives shells and platforms without accidental expansion.
- File transfer cannot exceed declared size, time, or cancellation limits.

## C5a. Scoped remote topology and projection boundary

Make the VM the authority for its own workspace graph. Every process in a
Cloud machine is hostile, including an agent launched by the user. At attach,
the control plane mints a lease bound to one machine, session, and explicit
remote workspace set. The daemon checks that lease on every topology action.

The remote agent may list, create, rename, move, reorder, and close VM-owned
tabs, panes, terminals, browser surfaces, and viewer surfaces in that lease. It
may apply an atomic layout and send terminal or VM-browser input. It may not
enumerate local workspaces or windows, receive host IDs, call the host socket,
use host paths or URLs, access host clipboard, keychain, SSH agent, or execute
a local process. A `current` selector is resolved by the VM daemon only.

Start an agent lease with one remote workspace. `workspace list` returns that
workspace plus workspaces created by the same lease. A new workspace joins the
lease. Adopting a pre-existing workspace requires a host or orchestrator grant.
This prevents agents in one VM from mutating each other's layouts.

V1 creates one dedicated local Cloud workspace for each attached remote
workspace. It contains only projections of resources owned by that VM. A local
user can move the whole projection workspace. A remote agent can move only
remote resources in its lease. Existing host-only placement may show a remote
resource in a local workspace, but it uses a separate remote region. Remote
control of mixed local and remote layouts is deferred.

Reuse the local placement and viewer rendering code behind a typed projection
adapter. Do not reuse host authority. A projection binding maps a remote
resource ID to a local placement, but host IDs never cross the link. The host
broker checks machine, session, workspace, revision, nonce, expiry,
idempotency, size, and rate limits. It never forwards a local socket or a
generic RPC method.

Use separate wire types for `GuestPath`, `HostPath`, `VmFileRef`, `VmUrl`, and
`HostUrl`. A `VmFileRef` contains only a grant ID, normalized relative path,
and digest. The VM browser may translate it to a `file:` URL inside the guest;
the host never sees or resolves that URL.

The desktop bridge implements separate remote views for terminal I/O, browser
frames, document models, and VM display frames. They share `RemoteResourceRef`
and revision handling, but none accepts a host path, host URL, host surface ID,
or generic local RPC.

Topology control flows through the VM daemon, not directly to the Mac:

~~~text
agent → VM-local cmux socket → lease check → remote mutation
      → event/snapshot → host projection reconciler → local Cloud workspace
user input → projection binding → VM daemon
~~~

The reconciler mirrors only the leased remote workspace and rejects events
that name a local resource or an unknown revision. A remote agent never sends a
host-layout mutation.

Leases carry quotas for workspaces, surfaces, frame size, event rate, terminal
output, and browser input. The host projection enforces them before allocating
a pane or decoder. Remote events cannot steal host focus or create unbounded
windows. Audit records contain only machine, session, workspace, action,
request ID, result, and byte counts.

Remote file and viewer commands execute in VM context:

~~~text
cmux open ./file
cmux diff --repo .
cmux markdown open ./plan.md
cmux browser open http://127.0.0.1:3000
~~~

The daemon canonicalizes paths against the VM project root and rejects
traversal, unsafe symlinks, and paths outside the grant. It sends bounded,
immutable file snapshots, structured diff hunks, or inert Markdown render data
to the local projection. The host never resolves a remote path or calls OS
`open`. Scripts, active HTML, remote subresource fetches, executable bundles,
and unsafe archive extraction are blocked. Binary and video previews use a
sandboxed decoder or a VM-rendered stream. Each action creates a durable
VM-owned viewer surface and returns its remote ID when no host is attached. A
later attach restores it from a revisioned snapshot. Remote link clicks return
to the VM resolver. File links open VM viewer surfaces, HTTP links open the VM
browser, and custom schemes are rejected. Diff mutations use expected blob
hashes and affect only the VM repository.

The browser process and network stack run in the VM. The local pane is a pixel
and input viewer, not a host WebView. Agent DOM, JavaScript, cookies, storage,
downloads, and browser profiles stay in the VM. `file:` is limited to the VM
project grant. HTTP access allows the VM's loopback and assigned interface
addresses plus exact VPC peer IPs from directed grants. The default agent
policy is `vm-vpc`; public egress and the machine's published domain are
explicit machine policies. The VM firewall and browser proxy enforce
this policy for DNS, redirects, subresources, WebSockets, and WebRTC, and
block the host gateway, Mac LAN, link-local, metadata, and private ranges
unless a directed peer grant allows them. Address checks canonicalize IPv4,
IPv6, mapped, integer, and DNS forms before every connection. VPC reachability
never grants cmux control of another VM.

The daemon control endpoint is not exposed as a peer service. Bind it to VM
loopback when possible. If a private listener is required, its firewall admits
only the authenticated host or relay route, and cmux-remote still performs its
end-to-end handshake. A directed peer grant may expose an application port,
never the daemon control port.

Use `vm-vpc` as the default agent egress policy. It permits the VM's loopback,
assigned interface addresses, and exact peer IP and port grants. `internet` is
an explicit user or team policy that adds public destinations. An own published
domain must be separately allowlisted if the agent needs to test it. Every
policy keeps host, metadata, and unapproved private ranges blocked. The guest
firewall and browser proxy enforce the policy.

Browser downloads stay in the VM. A host-side `cloud vm pull` with a selected
destination is the only path to the Mac. Drag, drop, paste, camera, and
microphone never create implicit host shares.

Local files and the local browser are not remote agent targets. If a user wants
to provide a host file, the user starts a local `cmux open` action or performs
an explicit one-file, bounded transfer. The VM never supplies a host path,
requests a picker, or receives a host viewer handle. A future isolated browser
handoff needs a disposable profile, origin policy, visible approval, and a
separate audit contract.

Acceptance:

- A hostile VM lists and mutates only its machine's leased workspace resources;
  `machine:local` and every host ID are rejected.
- Remote layout, move, close, terminal, and browser actions cannot affect a
  local workspace or a resource owned by another machine.
- VM file, diff, and Markdown paths reject traversal and symlink escapes and
  produce bounded, inert snapshots.
- A VM browser can reach its own loopback, interface addresses, and an exact
  granted VPC peer, but not the host gateway, Mac LAN, metadata service, or
  private range; redirects and DNS rebinding are rechecked.
- The host renders VM browser frames without loading the URL in a host browser,
  and no host cookie, DOM, pixel, path, clipboard, or keychain data returns.
- Revoking a session or destroying a machine invalidates projection bindings,
  browser streams, input leases, and peer grants.

VNC, noVNC, and browser frame streams are VM-to-host only. The host never sends
desktop, accessibility, camera, or microphone frames to a VM. Computer-use
input from a remote agent terminates at the VM display adapter.

### 80/20 release cut

The first secure vertical slice contains one machine, one leased workspace,
remote terminal and topology control, VM file/diff/Markdown snapshots, VM
browser frames and input, explicit VPC peer rules, and automatic local
projection. It rejects host paths, host browser control, host socket access,
mixed-layout remote control, recursive host mounts, and implicit clipboard or
download transfers. Public domain publication remains in the release, but it
publishes only a VM port through the managed edge and never changes the host
browser or host route table.

## C6. VPN, private routes, ports, and domains

Implement separate resources and commands:

~~~text
cmux cloud network status|peers|routes|connect|disconnect
cmux vpn status|up|down|revoke|hosts
cmux cloud port list|open|close|forward
cmux cloud domains list|zones|verify|publish|access|rm
cmux cloud vm link|unlink
~~~

The system VPN serves operating-system traffic and may require Network
Extension or root. cmux-wg provides an authenticated userspace link for
attach, remote terminal, and selected clients without root. A Mac hub and iOS
in-process tunnel must share route generations and peer-grant policy.

Private ports return tokened endpoints and probe bind reachability. Public
publication is a separate verified-zone resource with TLS, access mode, health
state, and cleanup. Domain operations never become an alias for port open.
Machine-to-machine routes require directed grants naming the destination machine,
IP, port, and protocol, not team membership alone. `cloud network` changes
Cloud routes only. `vpn up|down` changes host routes and is host-user-only.
OpenSSH fallback disables agent forwarding and host keychain access unless a
user explicitly chooses an isolated key. Local port forwarding binds loopback
by default and never auto-opens a host browser.

Public custom-domain publication is a managed-edge action. The Rust client
validates the zone, access mode, and machine route in the publish request and
returns a typed `action_unsupported` result when the deployment lacks the TLS
publication contract. It must not silently expose an opaque deployment URL or
switch infrastructure.

The domain verbs and user flow are a compatibility requirement, not a new
proposal. Rust must preserve the existing Cloud domain contract:

~~~text
cmux cloud domains [list]
cmux cloud domains zones
cmux cloud domains verify <domain>
cmux cloud domains publish <vm> <port> [--domain <hostname>]
  [--access personal|team|public] [--team <team-id>]
cmux cloud domains access <hostname> <personal|team|public> [--team <team-id>]
cmux cloud domains rm <hostname>
~~~

list is the default and accepts ls. zones accepts custom. rm accepts remove
and delete. cmux vm domains remains an alias during migration. verify is a
zone operation: the normal input is a base zone, while an owned publication
hostname or publication/domain ID may resolve to that zone for compatibility.
The first call prints the labelled ownership TXT, apex and wildcard routing,
and _acme-challenge delegation records; the user updates DNS and repeats the
same command. Generated friendly one-label names under the reserved cmux.sh
zone skip customer DNS proof; users cannot choose a label there. publish
defaults to personal, requires a team ID for team access, and
uses no forward-auth check for public access. The preferred flow verifies a
custom zone before publish. If publish runs first, it creates a durable
provisioning record without a serving rule, and the repeated verify command
finishes it. access and rm use the publication hostname as the user-facing
selector, accept the existing publication ID for compatibility, and return
the same URL-first human view and stable JSON shape as the Swift command. rm
keeps the existing no-prompt invocation during the compatibility window; the
backend still requires exact ownership and completes edge cleanup before
reporting success.

The Rust implementation must retain the flow from
[the public-domain design](../feat-cloud-vm-public-urls/DESIGN.md): edge TLS
and DNS operations remain backend-owned, protected viewers use the
sign-in or denial page with no request-access action, and unpublish or VM
deletion removes authorization and the exact edge rule before local
cleanup. Do not replace this with a singular domain namespace, an ID-only
workflow, or a generic port-open command.

Expert review question: can a public URL accidentally expose a private service,
or can a local VPN command alter Cloud policy? If yes, boundaries are mixed.
Edge networking, DNS, certificates, and private keys remain backend-owned.

Acceptance:

- Internal machine names resolve only through the selected private route.
- Userspace attach works without a system VPN prompt where advertised.
- Public publication supports zone verification, TLS readiness, personal, team,
  and public policy transitions, health reporting, and unpublish cleanup.
- Removing a machine or domain disables and sweeps dependent routes.
- Route and key rotation are observable and recoverable.

## C7. Project environments and layouts

Implement:

~~~text
cmux project list|show|dev|env set|env list|env rm|sync
cmux cloud vm dev
~~~

Define .cmux/cloud.json as a reviewable recipe containing repository and branch
identity, lockfile and toolchain digests, setup commands, secret references,
services, checks, ports, image requirements, workspace layout, and agent
defaults. It cannot contain secret values, infrastructure calls, local surface IDs,
or arbitrary executable hooks.

vm dev must route by explicit work key, then repository and branch, then a
stable caller-directory hash. It performs digest-aware sync or clone, detects
toolchains and devcontainers, replays changed setup steps, creates or reuses
a named workspace, runs bounded checks, and returns a receipt.

Add dry-run and plan output before mutating a project. Add lockfile and image
mismatch diagnostics. Add watch and push only after one-shot sync is reliable.

Expert review question: can an agent predict what vm dev will mutate before it
runs? If not, the manifest and plan are insufficient. A generated shell script
is not a project contract.

Acceptance:

- Two branches in one repository route to distinct workspaces.
- Re-running unchanged setup does no duplicate work.
- Secret references resolve by policy without exposing values.
- The receipt lists changed files, checks, ports, and workspace IDs.

## C8. Agents and CodeRouter

Implement declarative agent adapters and:

~~~text
cmux cloud agent list|run|get|wait|logs|stop|resume|fan-out
cmux cloud agent adapter list|describe|install|remove
cmux coderouter status
cmux coderouter session open|close|status
cmux coderouter usage team|machine|agent
cmux coderouter account list|add|enable|disable|remove|clear
cmux coderouter agent list|configure
~~~

### Shared CodeRouter implementation

Create a public `coderouter-core` repository with four small layers:

1. `coderouter-contract` contains the versioned JSON Schema, action IDs,
   request and response envelopes, error codes, usage records, route-authority
   metadata, and redaction annotations. Generate the TypeScript package and
   Rust protocol crate from one source.
2. `coderouter-client` is an async, transport-neutral Rust client. Inject the
   HTTP transport, auth adapter, clock, team scope, retry policy, and event
   sink. Keep account, session, usage, model, and route operations here.
3. `coderouter-handoff` implements secure handoff v2, short-lived route
   authority, environment scrubbing, and an agent invocation plan. It must not
   spawn a process or own a VM.
4. Frontends adapt the shared result to their product. The standalone binary
   owns TTY, local keyring, config, terminal UI, and local process launch. The
   cmux frontend owns cmux profile and team context, Cloud session selectors,
   and human or JSON rendering.

The current npm and PyPI CodeRouter distributions are native launchers. They
are not SDKs and cannot be imported by cmux. The cmux build must consume public
released core artifacts, never a private source repository or an installed
binary on `PATH`. This adds a release and fixture pipeline, but avoids two
independent auth and error implementations.

Both frontends map to the same action IDs:

| Standalone command | cmux command | Action ID |
| --- | --- | --- |
| `coderouter accounts` | `cmux coderouter account list` | `coderouter.account.list` |
| `coderouter add|remove|enable|disable` | `cmux coderouter account add|remove|enable|disable` | `coderouter.account.mutate` |
| `coderouter usage` | `cmux coderouter usage team|machine|agent` | `coderouter.usage.get` |
| `coderouter <agent>` | `cmux cloud agent run --agent <agent>` | `coderouter.session.open` plus `cloud.agent.run` |
| `coderouter login` | `cmux auth login` | `auth.session.get` |

Keep `cmux coderouter machines` and `cmux coderouter claude ...` as aliases
during migration. The final Rust namespace must not search `PATH` or silently
spawn another executable. An explicit, one-release compatibility flag may
delegate, and must label the result, preserve the exit code, and report the
contract version.

Use separate namespaced keyring entries and auth traits. cmux profile tokens
and standalone CodeRouter tokens are never copied between config files. A
service-side one-time exchange may create a model-only token when the user
links accounts. Team ID is explicit in every team-scoped request.

The shared client is asynchronous. The standalone binary uses a blocking
adapter, while cmux uses its existing async runtime. Shared fixtures test both
adapters, including token expiry, rate limits, cooldown, retry, redaction,
handoff replay, and usage attribution. Human output, JSON, and JSONL are
renderers over one envelope containing `contract_version`, `action_id`,
`request_id`, and redaction metadata.

Separate compute ownership from model routing. The machine owns the process
and workspace. CodeRouter owns upstream account selection, model route,
affinity, cooldown/failover, and usage attribution. A short-lived VM-bound
route token is edge-injected and is never written to the image or guest
credential file. Its audience, machine ID, session ID, expiry, and allowed
model actions are checked on every request. Agent launch removes host socket,
host filesystem, clipboard, keychain, and SSH-agent variables from the guest
environment.

Adapter manifests declare binary detection, launch/resume/stop, session-ID
extraction, hook installation, event mapping, required runtime conditions,
permissions, safe transcript sources, and the leased VM workspace scope. They
also list forbidden host resources. Claude, Codex, OpenCode, and Pi are
fixtures using this contract, not transport-specific branches.

Use the semantic event set for started, turn, approval, question, plan review,
error, and state changes. Derive blocked state from unresolved input, rather
than making blocked a lossy primary event. Fan-out requires explicit cost,
parallelism, cancellation, and aggregation policy.

Expert review question: can a new supported agent be added without modifying
Cloud transport or billing logic? If not, the adapter boundary is too weak.
Hardcoded agent names are a short-term patch that blocks accretive behavior.

Acceptance:

- Fresh and resumed Claude, Codex, OpenCode, and Pi runs route correctly.
- Account, model, team, and machine usage attribution is testable.
- Token expiry, upstream cooldown, rate limits, and retry behavior have
  durable receipts.
- A stopped run can be resumed without duplicating a completed turn.

## C9. Events, notifications, desktop, and mobile

Implement event cursors, bounded replay, gap recovery, and durable notification
commands:

~~~text
cmux cloud event stream|read
cmux cloud notification list|read|ack
cmux cloud desktop open|status
cmux cloud browser open|navigate|snapshot|input|close
~~~

The daemon is the data-plane owner of terminal and process events. The backend
is the durable ledger owner for machine, operation, agent, and notification
events. A client acknowledges only after rendering or persisting the event.
APNs and desktop notifications are delivery adapters, never independent
sources.

Desktop Swift uses the same resource IDs, action metadata, and receipts.
The iOS FFI surface stays narrow and data-plane focused. Lifecycle, billing,
and policy remain in Rust Cloud client and backend.

Expert review question: can two clients disagree about whether an agent needs
attention? If yes, event ordering, cursor ownership, or projection rules are
not explicit.

Acceptance:

- A disconnected client drains retained notifications in order.
- Cursor expiry returns a gap plus snapshot/describe recovery.
- Desktop and mobile show the same machine and session identity.
- Browser and VNC actions use the machine's explicit `desktop_ready` or
  `browser_ready` state.

## C10. Swift migration and removal

During one compatibility window:

1. Swift command names call the Rust client through a narrow bridge, including
   the CodeRouter namespace.
2. Swift renders the same generated response and error envelopes.
3. Existing aliases and human output remain stable.
4. A diagnostic reports whether a command is Rust-owned or a temporary local
   integration.
5. Swift retains only desktop projection, macOS keychain, NetworkExtension,
   window/pane composition, and explicit human approval.

Do not shell a Rust executable from Swift as the permanent boundary. If a
temporary subprocess is required, pin the binary and protocol manifest,
forward stdin/stdout without rewriting errors, and record the bridge in
telemetry. Remove duplicate Swift Cloud parsers after two release cycles with
migration metrics and a published deprecation record.

Expert review question: can the bridge disappear without changing the backend
contract? If not, it is hiding an architecture split and must be redesigned.

Acceptance:

- Swift and Rust produce equivalent JSON for the same fixture.
- No Swift-only Cloud mutation path remains after the migration gate.
- Linux, Windows, npm, and PyPI do not depend on Swift.

## C11. Package, bundle, and release hardening

Use one versioned Rust binary per target. npm and PyPI launchers select the
platform artifact and verify checksum, executable bit, protocol version, and
image manifest. The desktop app reuses its existing bundled Rust client;
measure the release-build delta after Cloud code lands rather than guessing
from debug artifacts.

Release the standalone CodeRouter npm and PyPI launchers independently from
cmux. Publish the public contract, generated protocol, async client, and
handoff artifacts before either frontend publishes a new action. A compatibility
matrix must reject a mismatched contract version before a request can mutate
state.

The clean-install matrix covers:

- macOS arm64 and x64;
- Linux arm64 and x64;
- Windows x64;
- no desktop app, no Bun, and offline help;
- login, team selection, VM list/create/wait, attach, exec, reconnect, and
  logout.

Publish provenance, SBOM, checksums, and a rollback channel. Verify that a
package cannot silently download an incompatible guest daemon. Keep the VM
image's cmux binary and protocol manifest pinned.

Add and run a deployment-neutral vocabulary check over public Cloud docs, package help,
and generated schemas before publishing. It rejects deployment names and
credential variable names; private deployment runbooks remain outside the
public package surface.

Expert review question: would a release maintainer detect an architecture or
protocol mismatch before a user loses work? If not, package validation is too
weak. A size estimate without a release build is not evidence.

Acceptance:

- Clean npm and PyPI installs pass the complete path.
- Desktop bundle contains one matching Rust client.
- Windows and Linux commands have equivalent JSON and exit behavior.
- Version and action mismatch fails with an actionable error.

## Cross-cutting test matrix

Every slice adds behavior tests in the narrowest suitable layer:

| Concern | Required proof |
| --- | --- |
| Auth and scope | profile isolation, team permissions, refresh rotation, redaction |
| Idempotency | retried create, restore, publish, destroy, and cancellation |
| Concurrency | revision conflicts, duplicate names, late backend callbacks |
| Transport | deadline preservation, reconnect, replay gap, bounded queues |
| Terminal | exact argv, PTY input, resize, signal, exit and close |
| Files | digest, resume, limits, cancellation, path policy |
| Network | route generations, grants, key rotation, internal DNS |
| Domains | DNS verification, TLS state, access transitions, cleanup |
| Agents | adapter lifecycle, semantic events, resume, attention state |
| CodeRouter | account affinity, token expiry, usage, cooldown failover |
| Events | cursor order, acknowledgement, retention and recovery |
| Distribution | clean OS installs, offline help, artifact identity |
| Security | no secrets in logs, images, argv, URLs, or receipts |
| Cost and policy | quota preflight, billing references, denied mutations |

Do not add tests that only read source files, plist files, or project files.
Prefer protocol fixtures, built artifacts, live API behavior, and hosted E2E.

## Release gates and deliberate exclusions

The first Cloud Rust release requires:

1. C0 through C5 complete on one machine path.
2. C6 private attach and public custom-domain publication complete. An access
   mode may be action-gated, but the typed zone, TLS,
   publication, health, and cleanup workflow must be shipped.
3. C8 supports the first selected agents with CodeRouter receipts.
4. Swift compatibility produces no divergent Cloud state.
5. Hosted E2E and clean npm/PyPI checks have run once.
6. Security review accepts token, grant, publication, and transfer boundaries.
7. Documentation links, generated schemas, and migration metrics are current.

Do not promise arbitrary external plugins, unrestricted fan-out, infrastructure
commands, or process continuity across restore before their action and
policy tests exist. These are explicit exclusions, not hidden TODOs.

## Open decisions requiring product input

- Should vm remain a documented alias indefinitely, or expire after migration?
- Which OS keyring fallback modes are allowed in CI and managed environments?
- Which desktop-only actions must have a headless equivalent before Swift Cloud
  commands are removed?
- What cost and concurrency limits apply to fan-out and long-running agents?
