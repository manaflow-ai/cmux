# cmux Cloud in Rust: system and CLI design

Status: proposed implementation contract. This is the canonical design for
moving Cloud behavior from the Swift CLI into Rust. It reflects the Cloud work
on main on 2026-09-03 and adjacent Cloud design work that is ready to
implement. It is not a claim that every command listed here exists today.

Related documents:

- [Rust public CLI specification](../cmux-tui/spec/cli.md)
- [Swift CLI compatibility contract](cli-contract.md)
- [Cloud cmux-tui daemon](cloud-cmux-tui-daemon.md)
- [Machine router](internal/machine-router.md)
- [CodeRouter operations](coderouter-operations.md)
- [Cloud guest command policy](cloud-guest-command-policy.md)
- [Implementation plan](../plans/feat-cloud-rust-cli/DESIGN.md)

## Outcome

The target user experience is one command contract available from a clean npm
or PyPI install, the desktop app, a Linux or Windows shell, and a Cloud VM.
The desktop app improves projection and human inspection, but it is not
required for Cloud control or a headless agent run.

An agent must be able to:

1. discover account, team, project, machine, session, network, and agent
   actions and constraints from local command help and typed responses;
2. choose a safe action from typed preconditions, permissions, cost, and
   side-effect metadata;
3. invoke it with stable IDs and idempotent retries;
4. observe progress, events, logs, and a durable result after disconnecting;
5. verify the result with a bounded, machine-readable check.

The product primitive is an action and lifecycle contract. The TUI, sidebar,
Swift app, npm launcher, PyPI launcher, and external adapters are clients of
that contract.

## Decisions

| Decision | Choice | Expert objection and response |
| --- | --- | --- |
| Cloud implementation owner | Rust owns the Cloud client, command behavior, models, errors, auth, and retries. Swift becomes a desktop projection layer and temporary compatibility bridge. | A fast wrapper that launches Swift or launches Rust from Swift leaves two parsers and two error contracts. That is cheaper for one release and expensive for every later feature, so it is not the final architecture. |
| Public namespace | `cloud <resource> [selector] <action>` is canonical. `vm` is a permanent ergonomic alias for `cloud vm`; established `vm agent` and `vm domains` spellings resolve to their canonical cloud actions. | One short vm namespace is easier to type, but it hides domains, teams, networks, and operations. The full namespace keeps discovery coherent while preserving existing scripts. One alias resolver avoids a second implementation. |
| Peer grant namespace | `cloud network grant list|create` and `cloud network grant <grant> show|revoke` are canonical. Existing `cloud vm link|unlink` forms are compatibility aliases. | Two first-class names for one authority object produce two help and error contracts. The nested form costs one word and gives every grant an ID, expiry, revision, and receipt. |
| Cloud object name | The server object is a machine; vm is its user-facing alias. | Renaming existing IDs would break scripts. IDs stay unchanged, and only the noun has a canonical spelling. |
| Control plane | Rust calls a versioned cmux Cloud API directly over HTTPS. The API remains backed by hosted web routes, Effect services, Postgres, and managed infrastructure adapters. | Making the app socket the only API blocks npm, PyPI, Linux, Windows, and guest workflows. Making clients call infrastructure directly leaks policy and credentials. |
| Data plane | Live terminals, workspaces, processes, events, and computer-use traffic use cmux-remote and its negotiated transports. | Rebuilding the data protocol in the HTTP client creates a second session implementation and loses replay and reconnect guarantees. |
| Network access | System WireGuard, userspace WireGuard, public port publication, and machine-to-machine grants are separate paths. | Calling all of them VPN or treating a public URL as a tunnel makes security and failure states ambiguous. |
| Asymmetric Mac access | The Mac can start an exact VM session. The managed network admits only return traffic for that flow and denies every new VM-to-Mac flow, reverse forward, route advertisement, and spoofed source. | A full-mesh VPN is simpler, but it exposes every Mac listener after one VM is compromised. Stateful one-way initiation adds network work and preserves attach, SSH, and projection without making the Mac a peer. |
| Guest authorization | One Rust binary selects a guest registry from an authenticated daemon handshake. The daemon and managed network enforce the boundary again. | A guest-mode environment flag is forgeable, and a parser-only allowlist fails after VM root replaces the client. Authority must be checked at its owner and outside the guest where required. |
| VM-to-VM access | Same-project machines receive encrypted routes to declared application services. Peer shell, exec, push, pull, raw ports, and cross-project routes need exact grants. | All-to-all private IP access is easy, but a compromised VM can scan and pivot through every service. Named services keep normal cooperation fast and limit lateral movement. |
| Same-VM isolation | One VM belongs to one project trust domain. Workspaces can share files and caches. Mutually untrusted work uses a separate warm VM or fork. | A workspace lease cannot provide data confidentiality when processes share one Unix user and process table. Separate VMs cost more and make the security claim true. |
| Root compromise | Mac denial, peer access, machine identity, API scope, relay admission, model authority, and projection parsing are enforced outside the VM. | VM root can replace its CLI, daemon, and firewall. Guest-only checks cannot support the stated boundary. External controls add implementation work and are required. |
| OS integration | Rust owns tunnel protocol, route policy, grants, and userspace WireGuard. Small native adapters call macOS NetworkExtension and platform keyring APIs. | Forcing privileged OS APIs into Rust would add unsafe FFI or a root helper. Keeping broad Cloud behavior in Swift would preserve the split. The native boundary is limited to OS facilities and has no Cloud policy. |
| Remote topology and host projection | The Cloud VM owns its workspace, tab, pane, terminal, browser, and viewer resources inside an explicit lease. The Mac owns a separate projection workspace and subscribes to VM state selected by the host user. A guest cannot choose host placement or enumerate host resources. | Letting a VM request host presentation creates a confused-deputy boundary. A host-selected mirror lets the agent organize its VM while the Mac keeps presentation authority. |
| Projection presentation | Each projected surface has host-owned machine and project identity. Host autofill, password managers, clipboard, drag and drop, automatic audio, and global input are disabled. | A sandbox does not stop a hostile VM from drawing a false host prompt. Trusted chrome uses screen space and keeps the trust boundary visible. |
| Projection input | Host input is bound to one projection ID, remote surface ID, and input epoch. Guest focus never selects the input target. Closing or replacing the target revokes the lease instead of retargeting input. | Sending input to the currently focused remote pane feels automatic, but a hostile guest can move focus before a keystroke arrives. Stable binding adds a reselect step after replacement and prevents input redirection. |
| Browser automation | Revisioned snapshots and typed `click`, `fill`, `press`, `wait`, `get`, `find`, and `screenshot` actions are primary. Pointer input and `eval` are VM-only fallbacks. | A minimal API is smaller, but it makes agents spend tokens on coordinates and fragile scripts. Semantic actions add protocol work and improve accuracy and errors. |
| Team scope | Login identifies a person. A selected team is explicit, persisted, and shown in every team-scoped mutation. | Inferring a team from the last response is convenient until a user has two teams. Silent cross-team mutations are unacceptable. |
| Long work | Mutations return an operation receipt when they can outlive one HTTP request. wait, watch, and cancel operate on that receipt. | A synchronous create endpoint is simple until the backend must resume a sleeping machine or reaches its request limit. Hidden background work is harder to recover than an explicit operation. |
| Machine creation latency | `cloud vm create` first claims a clean, single-claim warm machine for the requested region, size, image family, and persistence profile. The warm path targets p50 under 3 seconds to daemon-ready and p95 under 10 seconds. A cold path returns an operation immediately; the Rust client follows it by default so the command still returns a ready machine. `--no-wait` returns the operation for callers that want asynchronous control. | Always booting after the request gives strong isolation but makes every agent wait. Returning a used tenant machine to the pool makes secure erasure hard to prove. A single-claim pool costs standby compute and preserves a fresh-image trust boundary. Making cold waits implicit can surprise an interactive user, so progress, a bounded default deadline, and `--no-wait` are required. |
| Action validation | The client performs a small protocol, identity, and authorization check for each action. Action-specific state appears in the action response; there is no generic feature list and no required `cloud capabilities` discovery command. Unsupported actions return a typed error with the next valid action. | Removing validation entirely makes version skew fail as confusing transport errors. Keeping a large action-list command makes agents spend a round trip on information they do not need. Bounded checks preserve safety without a ceremony step. |
| Effect and result typing | Every atomic action declares its complete effect set. Every command has one primary result shape: result, receipt, operation, stream, interactive, or transfer. | One effect per action is false for browser open, which creates viewer, topology, and network effects. Untyped output makes agents guess whether work continues. The schema work removes hidden authority and hidden work. |
| Close lifecycle | Layout close actions detach resources. Resource-specific close actions end them. | One `close` meaning is familiar but can kill work during layout changes. The explicit split makes destructive intent visible. |
| CodeRouter reuse | A public versioned contract, generated protocol types, transport-neutral Rust client, secure handoff library, and command engine are shared by standalone `coderouter` and `cmux coderouter`. Each product keeps only its keyring, config, terminal context, and process adapter. | Linking the standalone npm package into cmux is not reproducible because it is a binary launcher. Keeping two parsers or renderers creates help, auth, error, and output drift. Published Rust crates plus one injected command engine add a release dependency and remove that drift. |
| Guest model authority | A guest receives a VM-local model endpoint. The managed edge adds short-lived authority after it verifies source machine identity outside the VM. | A bearer in guest memory is easy to add, but VM root can export it. The identity path takes network work and stops portable model and Cloud credentials. Root can still spend its machine allowance. |
| Distribution | The desktop app reuses the already bundled Rust binary. npm and PyPI launch the same versioned binaries. | Shipping a second Cloud binary increases size and creates version skew. The current universal client is about 56 MB arm64 plus 59 MB x86_64, about 115 MB before Cloud code is measured. |
| First Cloud release | Public custom-domain publication is included, behind verified zones, TLS state, access policy, health checks, and cleanup. | Deferring domains leaves the main production workflow dependent on opaque deployment URLs and leaves the public/private boundary untested. Shipping an unverified or policy-free URL would be worse, so the gate is the complete publication lifecycle, not a port alias. |
| Established domain deletion UX | Keep domains rm hostname as a single command with the existing aliases and output. Enforce exact owner, hostname, revision, idempotency, and edge cleanup in the backend. | A confirmation prompt would reduce accidental deletion, but it would break the shipped Ben Swerdlow flow and scripts. The exact-host and owner fences contain that risk; a new prompt needs a versioned UX decision, not a silent Rust change. |

These choices trade a larger first contract for one source of truth. The
residual risk is migration complexity while Swift and Rust coexist. The plan
limits that period and makes the compatibility boundary observable.

### Public vocabulary boundary

Public CLI help, API schemas, package metadata, and Cloud design documents use
role names such as machine, image family, managed edge, and backend. They do
not expose deployment or vendor names. Internal adapter identifiers and
historical migration records may retain existing names until the implementation
migration removes them; those identifiers must never appear in user output,
logs, or new public contracts. A vocabulary check is a required CI gate over
public Cloud documents and generated help. Private operational runbooks may keep
exact deployment selectors and secret names until their corresponding runtime
migration lands; they are excluded from the public contract check and must not
be copied into agent-facing help.

## System model

### Resource graph

Cloud state is one graph. A command may start at any node, but its response
identifies the complete path and the authority used.

~~~text
account
└── team
    └── project
        └── machine
            ├── workspace
            │   └── terminal
            │       └── process
            ├── agent run
            ├── network attachment
            │   ├── private route
            │   ├── port publication
            │   └── peer grant
            ├── snapshot / fork
            └── operation / event stream
~~~

Stable resources and lifecycle:

| Resource | Identity and owner | Important lifecycle |
| --- | --- | --- |
| Account | cmux account identity | signed out, signed in, revoked |
| Team | cmux team ID | selected, membership changed |
| Project | server project ID with a repository binding | discovered, configured, archived |
| Machine | opaque server machine ID; display name is not identity | provisioning, ready, sleeping, waking, failed, destroyed |
| Workspace | opaque daemon workspace ID, scoped to a machine | open, closed, recoverable |
| File grant | VM project root plus normalized relative path scope, scoped to a machine/session/workspace | active, narrowed, revoked |
| Projection binding | local-only mapping from a remote resource to a host placement; never sent to the VM | attached, moved, detached, revoked |
| Terminal | opaque daemon terminal ID, scoped to a workspace or detached pool | running, exited, detached, closed |
| Process | opaque daemon process ID | reserved, running, exited, replay expired |
| Agent run | server run ID bound to an adapter and terminal | queued, running, waiting, completed, failed, canceled |
| Snapshot | immutable snapshot ID, source machine and generation | creating, ready, restoring, expired, deleted |
| Network attachment | device or machine identity plus route generation | enrolling, active, stale, revoked |
| Peer grant | directed source and destination machine IDs | active, revoked |
| Port publication | machine, port, protocol, and access policy | probing, open, stale, closed |
| Domain and publication | verified zone plus exact hostname route | pending, verified, active, disabled, removed |
| Operation | server operation ID and request ID | queued, running, succeeded, failed, canceled, indeterminate |
| Event stream | owner, subject, cursor, and retention window | subscribed, replaying, live, gap |
| Notification | durable event ID and recipient scope | pending, delivered, acknowledged, expired |

Every resource ID is opaque and stable. A display name is a selector only. A
name that matches more than one resource returns selector.ambiguous with all
candidate IDs. The client never picks one by recency, sort order, or focus.

Host file handles, host browser profiles, and host viewer surfaces are local
resources. They are never Cloud resources, never included in the machine graph,
and never addressable by a VM resource ID. A Cloud projection response may
return a remote-resource receipt, but it must not return a host path or a host
surface ID that can be used for readback.

Every mutable resource has a server revision. Mutations may include
expected_revision; a stale value returns revision_conflict without a partial
effect. A response includes the new revision or an operation whose result will
include it.

### Two planes and one composition root

~~~text
CLI / SDK / Swift projection
          │
          ├── cmux-cloud-client ── HTTPS cmux Cloud API ── Postgres + managed edge
          │                              │
          │                              └── operations, auth, billing, policy
          │
          └── cmux-remote client ── private direct / relay link ── cmux-tui daemon
                                          │
                                          └── workspaces, PTYs, agents, events
~~~

The control plane decides who may act, which machine is selected, what the
managed infrastructure can do, and how a mutation is billed. The data plane carries live
terminal and event traffic after the control plane has issued a scoped route.
The planes share resource IDs and request tracing, but neither substitutes for
the other.

Rust crate ownership:

| Layer | Initial owner | Boundary |
| --- | --- | --- |
| Wire models and schema | cmux-cloud-protocol, new | serde models, JSON Schema, action and error enums; no I/O |
| Cloud API client | cmux-cloud-client, new | HTTPS, auth adapter, team context, retries, idempotency, operation polling |
| CodeRouter contract | coderouter-contract, new public schema package | model-plane action IDs, request and response envelopes, errors, usage, and route-authority metadata; no secrets or I/O |
| CodeRouter protocol | coderouter-protocol, generated Rust crate | Rust types and action metadata generated from coderouter-contract; no global state |
| CodeRouter client | coderouter-client, new transport-neutral library | async model-plane requests, auth traits, session/account/usage operations, retries, redaction, and deadlines; no TTY, filesystem, or process spawning |
| Agent handoff | coderouter-handoff, new shared library | VM-local endpoint configuration, environment scrubbing, and invocation plans; no portable guest credential or process ownership |
| CodeRouter command core | coderouter-command, new shared library | parser fragment, help, dispatch, normalized results, and renderers; injected auth, terminal, and process adapters |
| Public command frontend | cmux-tui Cloud command module | argv, help, output, exit codes, stdin and terminal policy |
| Live remote transport | cmux-remote | enrollment, Noise identity, replay, sessions, terminal and event streams |
| Private link | cmux-wg | userspace WireGuard and dialer; no Cloud policy |
| Embedded terminal view | cmux-terminal-client | small FFI surface for iOS and future embedded clients |
| Desktop composition | Swift app | construct clients, project resources into panes, human approval, local OS integration |
| Backend | web/app/api, web/services/vms, CodeRouter services | auth, policy, billing, managed-edge calls, DNS, TLS, durable state |
| Guest | baked cmux-tui daemon and signed adapters | terminal ownership, local process execution, bounded event production |

The executable app remains the composition root for Swift objects. Rust
libraries receive explicit clients, clocks, stores, and transports. No new
package relies on a singleton or the user's default filesystem.

### Reuse without authority leaks

Share pure protocol and rendering models. Keep authority-bearing adapters
separate:

| Shared code | Host implementation | VM implementation |
| --- | --- | --- |
| Resource IDs, lease envelope, revisions, layout operations | Maps remote IDs to local placements | Validates and mutates the VM workspace graph |
| `FileSnapshot`, `DiffModel`, `MarkdownModel`, and bounded media metadata | Sandboxed read-only renderer | Reads only the VM project grant and produces snapshots |
| Browser navigation, frame, input, and DOM message schemas | Displays VM frames and forwards explicit input | Owns the browser process, profile, DOM, and network policy |
| CodeRouter action and handoff schemas | cmux frontend and keyring adapter | Guest process receives a VM-local endpoint with no portable bearer |

Use distinct types for `GuestPath`, `HostPath`, `VmFileRef`, `VmUrl`, and
`HostUrl`. Do not let a generic string path or URL cross the boundary. The
wire format carries a `VmFileRef {grant_id, relative_path, digest}` rather than
a raw `file:` URL; the VM browser may translate it to a local file URL only
inside the guest. The placement planner can be shared because it consumes
opaque resource IDs and a typed destination. The host adapter alone can resolve
a local placement ID; the VM adapter alone can resolve a guest path or browser
target. This gives one command experience and one result schema without one
authority domain becoming another.

The browser protocol is transport-neutral, but the browser engine is not
shared. A VM browser adapter owns Chromium or the desktop browser in the VM.
The Mac adapter owns only a frame renderer and input channel for a Cloud
browser. The local host browser remains a separate local feature. This avoids
the tempting but unsafe shortcut of sending a remote URL to the host WebView.

The desktop projection has four narrow adapters: a remote terminal view for
manual terminal I/O, a remote browser view for frames and input, a remote
document view for file/diff/Markdown models, and a remote desktop view for VM
display frames. All four consume `RemoteResourceRef` and revisioned data. None
accepts a host path, host URL, host surface ID, or arbitrary local RPC.

## Cloud API contract

### Versioning and generated models

The public Cloud contract is cmux.cloud/v1. Existing /api/vm/*,
/api/coderouter/*, and /api/vm/tunnel routes remain compatibility routes while
the versioned client facade is introduced. They map to the same backend
services and database rows, not to a second state store.

The contract source is a checked-in, versioned schema package owned jointly by
the Rust and web teams. Backend route definitions implement that package;
they are not an implicit contract generator. CI must:

1. generate Rust and TypeScript models and action metadata;
2. compile the Rust client against the generated models;
3. run fixture conformance for every request, response, action precondition, and error;
4. reject a breaking change unless the API version changes or an explicit
   compatibility record exists.

Hand-written Swift dictionaries and backend response types are not a
contract. The Swift bridge decodes the generated wire shape during migration.

### Request envelope

Every Cloud request carries:

| Field or header | Purpose |
| --- | --- |
| API version | Rejects unsupported clients before a mutation |
| authenticated principal | cmux account token, or a narrower machine principal |
| team ID | Explicit team context when the resource is team-scoped |
| client ID and version | Package, desktop, guest, or embedded client identity |
| client request ID | UUID allocated before network work, used in logs and support |
| trace context | Joins web routes, managed edge, CodeRouter, and client timing |
| idempotency key | Required for every mutation and stable across safe retries |
| expected revision | Optional optimistic concurrency fence |
| deadline | Absolute deadline, never an unbounded phase timeout |

Tokens, credentials, request bodies, and terminal bytes are never put in a
client request ID, trace attribute, URL query, or diagnostic message.

When a caller omits an idempotency key, Rust allocates one before the first
network request and echoes it in every operation receipt. Callers that need to
resume after a process exit persist that key with the operation ID; they never
retry a timed-out mutation with a new key just to see whether it worked.

### Response and errors

Successful responses have a common outer shape:

~~~json
{
  "api_version": "cmux.cloud/v1",
  "request_id": "req_01...",
  "trace_id": "trace_01...",
  "revision": 42,
  "data": {}
}
~~~

The new facade does not emit a generic capability or feature array. A
compatibility route may still send `capabilities` or `features`; the client
accepts and ignores those legacy fields at the boundary. Command behavior uses
typed action data and typed errors, not an action-list response.

Long mutations additionally return an operation:

~~~json
{
  "data": {
    "operation": {
      "id": "op_01...",
      "kind": "machine.create",
      "state": "queued",
      "resource_id": null,
      "poll_after_ms": 500
    }
  }
}
~~~

Errors have stable fields:

~~~json
{
  "error": {
    "code": "machine.not_ready",
    "message": "The machine is still waking.",
    "retryable": true,
    "action": "wait for operation op_01...",
    "details": {}
  },
  "request_id": "req_01...",
  "trace_id": "trace_01..."
}
~~~

message is safe for a human. code, retryable, action, and details are for
agents. Backend error text is retained only in redacted operator telemetry.
The client maps transport failures, auth expiry, rate limits, revision
conflicts, scope denial, unsupported actions, backend failures, and
indeterminate effects to stable codes. `scope.denied` includes the machine,
session, workspace, and resource class that failed the check, but never a host
path or host identifier.

### Operations and cancellation

An operation is the only place where asynchronous work is hidden:

~~~text
queued -> running -> succeeded
                 ├-> failed
                 ├-> canceled
                 └-> indeterminate
~~~

indeterminate means an external effect may have happened but the result was
not observed. The server exposes reconciliation by idempotency key. The client
does not blindly repeat a create, destroy, publish, or restore.

The client exposes:

~~~text
cmux cloud operation <id> show
cmux cloud operation <id> wait [--timeout <seconds>]
cmux cloud operation <id> watch
cmux cloud operation <id> cancel
~~~

Cancellation is cooperative. A canceled request receives a durable tombstone,
and a late backend callback cannot resurrect the resource or overwrite a newer
revision. Cleanup is idempotent and runs after the caller exits.

A local deadline does not cancel backend work. The client returns the operation
receipt with an indeterminate or running state, the generated idempotency key,
and `cloud operation <id> wait` as the next action. Cancellation requires an
explicit command and its own receipt.

### Action checks

The protocol validates a small version, identity, and authorization envelope at
the start of each request. It also checks the selected machine's generation and
image family when an action needs them. This protects against version skew
without making an agent request a large action list first.

There is no required `cloud capabilities` command. Local help is the primary
discovery surface, and `--help --json` returns the inputs, permissions,
side-effects, limits, and output shape for one command. An attempted action
returns `action_unsupported` with the supported replacement or the required
upgrade when the current machine cannot perform it. `cloud doctor` is an
exceptional diagnostic for a human or an incident runbook; normal workflows do
not call it.

Capabilities are not a Cloud product primitive. The only capability fields that
remain are private cmux-tui transport handshake fields, where independently
updated peers need a bounded compatibility bit. Cloud requests use a version,
an action ID, and explicit preconditions. They do not fetch or persist a Cloud
capability catalog.

The request check is deliberately bounded to protocol version, client identity,
machine generation, and the requested action. It does not enumerate backend
implementation details or expose infrastructure names.

## Authentication and trust

### User login

cmux auth login uses a device/browser flow. The current
/api/vault/cli/auth/{start,poll,approve} implementation is the compatibility
backend. The Rust client gives it one typed facade and keeps the old paths
behind an adapter.

The auth store is injected and platform-specific:

| Platform | Primary store | Fallback |
| --- | --- | --- |
| macOS | Keychain | none by default |
| Linux | Secret Service or a user keyring | mode-0600 encrypted file after explicit opt-in |
| Windows | Credential Manager | mode-restricted user store after explicit opt-in |
| CI or one-shot job | process memory from stdin | no persistent token |

Access tokens are short-lived. Refresh tokens are rotated, bound to the
profile, and removed on logout or refresh-token reuse detection. auth status
prints account and expiry metadata, never token values. token-stdin is allowed
for automation; token on argv is rejected.

Profiles are named. A profile contains account and team context, API origin,
and device identity, but never an infrastructure secret. The active profile is
explicit in JSON and can be selected with profile. Commands fail rather than
silently switching profiles.

### Team and machine principals

cmux team list, cmux team use <id>, and cmux team current manage the selected
team. Every team mutation includes the selected team ID in its request and
response. A missing selection is an error for a team-only action.

A Cloud VM never receives a user's cmux account access or refresh token. At create,
the backend may mint a short-lived machine-scoped principal and store only its
hash. The managed edge injects the principal only to the named cmux API origin.
Scopes are deny-by-default:

- control only resources in the named machine and leased workspace;
- read the machine's own status and peer services in the lease;
- reach same-project application ports declared by the project manifest;
- attach, peer exec, peer push, peer pull, or notify only through an exact
  grant;
- never create, destroy, snapshot, change billing, or widen a grant.

The router binds one machine principal to one project trust domain. Workspace
leases limit cmux API effects, but they do not isolate files or processes that
share the same VM Unix authority. An isolation request claims another warm VM
or snapshot fork.

`cmux cloud network grant create <source> <destination> --service web --allow
connect --ttl 1h` grants one declared service. `--endpoint tcp:3000` is the
exceptional raw-port form. `--allow shell|exec|push|pull` grants one stronger
peer action. Existing `cloud vm link|unlink` forms are compatibility aliases.
A peer action uses a VM-local broker. The managed network combines the grant
with source machine identity, so no portable destination bearer enters the
guest.

### Secret rules

- No token or credential in argv, environment snapshots, logs, journal
  records, URLs, package metadata, or VM images.
- Infrastructure, CodeRouter, DNS, and certificate credentials stay in backend
  services or edge rules.
- Agent configuration in a guest contains endpoints and placeholders, not
  bearer secrets. The managed edge adds short-lived authority only after it
  verifies source machine identity outside guest control.
- Public URLs are treated as bearer credentials and are redacted from logs.
- File transfer and exec responses have bounded sizes and explicit
  cancellation.

### Remote workspace authority and host isolation

Every process in a Cloud machine is hostile. The VM is the authority for its
own resource graph. The Mac is a projection client. A remote principal receives
a lease bound to `machine_id`, `session_id`, and one or more explicit remote
workspace IDs. Every workspace, tab, pane, terminal, browser, file, Markdown,
and diff resource carries that owner and scope. `current` resolves only inside
the VM daemon and never means the host's focused workspace.

The lease allows a remote agent to list, create, rename, move, reorder, and
close VM-owned tabs, panes, and surfaces, control VM terminals, send input to a
VM browser, and apply an atomic layout to the leased workspace. It denies local
workspace or window enumeration, host IDs, host socket or RPC access, host
focus or selection, host paths and URLs, clipboard, keychain, SSH agent, and
local process execution. The remote agent can move only resources whose owner
is the same machine and whose workspace is in the lease.

The default agent lease starts with one remote workspace. `workspace list`
returns only that workspace and workspaces created by the same lease.
`workspace create` adds the new remote workspace to the lease. Selecting or
adopting a pre-existing workspace requires a host or orchestrator grant. This
keeps agents in one VM from changing each other's layouts while still letting
one agent organize a multi-workspace task.

V1 creates one host-owned projection container for each attached remote
workspace. The container is a dedicated Cloud workspace or a bounded pane
subtree and contains only projections of resources owned by that VM workspace.
A local user can move or close the complete container. Remote tab, pane, and
surface events can change only descendants of it. A guest-created workspace
appears in the Cloud tree and stays closed until the host attaches it. A remote
agent cannot cross the container boundary, select a local workspace, create a
top-level Mac surface, or change Mac focus. Remote control of mixed local and
remote layouts is deferred.

Projection mirrors remote layout and ignores remote focus by default. A host
can opt one container into follow-focus. That mode can select only a descendant
inside the container and cannot activate another Mac window or take keyboard
focus. `open`, `diff`, `markdown open`, and `browser open` keep their normal
placement grammar but apply it to the caller's leased VM workspace. They return
the VM resource ID when no host is attached. If a projection exists, its
reconciler displays the resulting topology event inside the container.

Projection is a host-selected subscription to VM state and a source only for
explicit user input. The Mac starts the authenticated circuit. A local
placement binding maps a remote resource ID to a host placement, but host IDs
never cross the link. The host broker accepts typed VM events and
checks identity, machine, session, workspace lease, revision, nonce, expiry,
idempotency key, size, and rate limits. It mirrors only the selected remote
projection. It never forwards the local socket and never grants host authority.

Text that the user types into a selected projection is intentionally sent to
the VM and is visible to VM root. The host shows unforgeable machine identity,
disables autofill, password managers, clipboard, and global input, and binds
each input lease to one remote surface and epoch. These controls stop hidden or
retargeted input. They cannot protect a secret after the user sends it.

The request envelope is bounded and carries all scope:

~~~json
{
  "request_id": "req_...",
  "machine_id": "machine_...",
  "session_id": "session_...",
  "workspace_id": "ws_...",
  "action_id": "surface.move",
  "resource_id": "surface_...",
  "expected_revision": 12,
  "nonce": "...",
  "expires_at": "..."
}
~~~

Remote viewer actions stay inside the VM:

- `cmux open ./file`, `cmux diff --repo .`, and `cmux markdown open ./file`
  resolve paths against the VM project root. The daemon canonicalizes paths and
  rejects traversal, unsafe symlinks, and paths outside the project grant. It
  sends a bounded immutable file snapshot, structured diff hunks, or a rendered
  Markdown model to the host projection. The host never calls OS `open` on a
  remote path. Markdown scripts, active HTML, remote subresource fetches, and
  executable bundles are blocked. Video and other binary previews use a
  sandboxed decoder or a VM-rendered stream. Each command creates a durable
  VM-owned viewer surface and returns its remote ID even when no host is
  attached. A later attach restores the surface from its revisioned snapshot.
  Link clicks return to the VM resolver: an allowed file link opens another VM
  file surface and an HTTP link opens the VM browser. The host never handles a
  remote custom scheme. Diff and Markdown viewers are read-only. An edit uses a
  separate VM process action. File, diff, Markdown, image, and video resources
  use `cmux viewer <viewer> show|reload|close`. Video decode stays in the VM,
  and a guest-started host projection stays muted until the local user enables
  audio.
- `cmux browser open <url>` starts the browser in the VM. The local pane is a
  remote pixel and input viewer; it is not a host WKWebView loading the URL.
  Revisioned snapshots return stable element references. Typed `click`, `fill`,
  `press`, `wait`, `get`, `find`, and `screenshot` actions are the normal agent
  path. Pointer input and JavaScript evaluation are VM-only fallbacks.
  `file:` URLs resolve only inside the VM project grant. HTTP access allows the
  VM's own loopback and assigned interface addresses, declared same-project
  `project-app` services, and exact peer service grants. The default agent
  policy is `project`; public Internet and a machine's published domain need
  an expiring lease grant, not a host-network fallback.
- The VM namespace and browser proxy apply the URL policy as defense in depth.
  The managed network outside VM-root control is authoritative. Both resolve
  and recheck every redirect, subresource, WebSocket, WebRTC connection, and
  DNS result. They block the host gateway, the Mac LAN, link-local and metadata
  addresses, and private ranges unless an exact peer service grant allows that
  destination. Address checks canonicalize IPv4, IPv6, mapped, integer, and DNS
  forms before every connection. Peer reachability is network access only. It
  never grants another VM's cmux daemon control.

`project` is the default browser egress policy. It permits the VM's loopback,
assigned interface addresses, declared same-project `project-app` services,
and exact peer service grants. `machine-only` removes peer access. `internet`
is an expiring, lease-scoped host grant that adds public destinations and can
be limited to exact domain suffixes. Team policy can forbid or narrow it. An
own published domain must be separately allowlisted if the agent needs to test
it. Every policy keeps host, metadata, and unapproved private ranges blocked.
The URL parser and guest firewall are defense layers. The managed network
outside guest control is the hard boundary.

An attempted public navigation fails with `network.egress_denied`, its origin,
and a copyable host action such as `cmux cloud network egress <session> set
internet --ttl 1h --domain example.com`. The VM cannot approve or execute the
host action. The user changes the lease, then the agent retries. The client does
not open a hidden approval window or widen the policy automatically.

The cmux daemon control endpoint is not a peer application service. It binds to the VM
loopback when the transport allows it, or to a private listener whose firewall
allows only the authenticated host or relay route. Peer grants may expose an
application port, never the daemon control port. The daemon still requires the
end-to-end session handshake after a packet reaches the listener. A peer
cannot turn an allowed application route into a cmux session or use a browser
port as a control channel.

Browser downloads stay in the VM file grant. Moving one to the Mac uses an
explicit host-side `cloud vm <machine> pull` action with a selected destination. Drag,
drop, paste, camera, and microphone do not create implicit host shares.

The host must also treat all projected bytes as hostile. Remote terminal escape
sequences cannot write the host clipboard or invoke host schemes. Remote links
are inert by default. User paste and pointer input are explicit host-to-VM data
transfers and show the source machine. Local rendering is sandboxed and has no
filesystem, keychain, or shell authority.

Every projected surface has host-owned chrome that shows the machine and
project identity. VM pixels cannot cover it. Projection disables host autofill,
password managers, clipboard, drag and drop, automatic audio, and global input.
The host sends input only through a lease bound to the projection ID, exact
remote surface ID, and an input epoch created when the user selected that
surface. Guest focus never changes this target. Closing or replacing the
remote surface revokes the input lease. It does not retarget later keystrokes
to the new focused surface. A topology move can keep the lease only when the
same remote surface ID and projection binding survive. Guest focus remains VM
logical state and cannot focus a Mac window.

VNC, noVNC, and browser frames are responses on a host-started projection
circuit. The host never sends ScreenCaptureKit, accessibility, camera,
microphone, or desktop frames to a VM. A remote computer-use agent can operate
a VM desktop through the VM display and input channel, but it cannot operate
the Mac desktop. Pointer input names the frame sequence that supplied its
coordinates, and stale input fails.

Local files and the local browser are not remote agent targets. If a user wants
to show a local file or video to an agent, the user starts a separate local
`cmux open` action or explicitly shares one selected, bounded copy to the VM.
The picker and file descriptor stay on the host. The VM receives a generated
guest path and digest, never the host path or a shared mount. The transfer is
scanned, size-limited, immutable, and expires with the lease. The VM never
supplies a host path, requests a host picker, or receives a host viewer handle.
A future isolated host-browser handoff is a separate product,
with a disposable profile, origin policy, visible approval, and no existing
tabs or cookies.

Security invariants:

1. A remote principal never receives a host resource ID, path, cookie, or
   socket endpoint.
2. Every remote mutation is scoped to one machine, session, and leased
   workspace, and stale or revoked leases fail closed.
3. Every remote URL is resolved in the VM. The host never navigates on behalf
   of the VM.
4. Projection is a host-started display subscription plus explicit user input.
   It is not a general reverse data channel.
5. No shared host folder, socket, agent forwarding, clipboard, keychain, or
   credential is mounted into a VM.
6. Revoking a session or destroying a machine revokes all projection bindings,
   browser streams, input leases, and peer grants.
7. Guest focus never chooses the host input target. A closed or replaced target
   drops later input instead of sending it to another surface.

Threat checks must prove that a rogue VM's workspace listing returns only its
own leased resources, `file:///Users/...` fails inside the VM without reaching
the Mac, a `machine:local` projection request is rejected, a malicious Markdown
image cannot fetch a host file, a browser cannot probe the host gateway or
metadata service, and a replayed request fails after lease revocation.

Authority matrix:

| Principal | May do | Must never do |
| --- | --- | --- |
| Remote agent in machine | Control VM resources in its leased workspace; read VM files; use VM browser and granted peer services | Address host resources, another workspace, host network, host credentials, or another VM's daemon |
| Host projection broker | Map VM resources to a dedicated local Cloud workspace; carry explicit user input to the VM | Resolve VM paths on the Mac, load VM URLs in a host browser, or return host state |
| Local user | Control local workspaces and files; attach, move, or detach Cloud projections; approve bounded transfers | Accidentally grant a recursive host mount or an unscoped remote lease |
| Cloud control plane | Authenticate, authorize, create machines, issue leases, and revoke them | Carry terminal bytes or act as a hidden host proxy |

The guest starts its `cmux` commands against the VM-local daemon socket. The
host socket path is absent from the image and is not placed in guest
environment variables. The host initiates the authenticated outbound link and
accepts no unauthenticated inbound connection from the VM. This is the key
composition rule that makes local and remote cmux feel the same without making
the Mac part of the guest's trust domain.

### Three execution contexts

The command name stays familiar, but authority comes from the process context:

| Context | `cmux` resource verbs target | Local authority |
| --- | --- | --- |
| Guest | The VM-local daemon and the leased VM workspace | VM files, terminals, browser, and granted peer services |
| Host Cloud | The Cloud API and an attached remote session | Cloud machines plus local placement of their projections |
| Host local | The user's local cmux socket | Local workspaces, panes, browsers, and files |

Context is explicit at startup and never falls back. A guest request that
cannot reach its VM daemon fails with `transport.unavailable`; it does not try
the host socket. A host Cloud command that cannot attach fails with a remote
error; it does not silently run against the local workspace. This prevents a
remote agent from turning a missing remote resource into a local operation.

### Guest command policy

The [Cloud guest command policy](cloud-guest-command-policy.md) is normative
for the Rust parser, VM daemon, managed network, host projection, and agent
skill. Its short form is:

```text
context|tree|machine self|server status|session current read
workspace|screen|pane|tab|surface topology inside the lease
terminal|process|run|exec inside the VM
open|viewer|diff|markdown|desktop|browser inside the VM
peer list|show|resolve, plus granted forward|shell|exec|push|pull
agent|event|notification inside the VM
coderouter status|session show|model list|usage self
```

The policy contains the exact verbs, complete effect sets, result shapes,
host-only denials, and hostile-VM tests. The guest uses local `--help --json`,
`context`, `tree`, and typed action errors. There is no user-facing Cloud
capabilities catalog. Layout close detaches a resource. Only a typed
resource-specific close ends it.

The live control flow is:

~~~text
remote agent
  → VM-local cmux socket
  → VM daemon lease check and topology mutation
  → remote event / snapshot
  → host projection reconciler
  → dedicated local Cloud workspace
~~~

User input travels back through the existing projection binding to the VM
daemon. A remote agent never sends a direct host-layout mutation. The host
reconciler mirrors only the leased remote workspace and refuses events that
name a local resource or an unknown revision.

The circuit is host initiated and typed. It carries bounded VM frames, state
receipts, explicit user input, and acknowledgements. The guest cannot choose a
host endpoint, open a second channel, send raw protocol bytes, or request a
host fetch. A sandboxed parser has no filesystem, process, browser, device,
clipboard, keychain, or general network authority.

The lease also carries quotas for workspace count, surface count, frame size,
event rate, terminal output, and browser input. The host projection enforces
the same limits before allocating a pane or decoder. Remote events never steal
host focus or create an unbounded number of local windows. Redacted audit
records contain the machine, session, workspace, action, request ID, result,
and byte counts, never paths, content, cookies, or tokens.

### End-to-end agent flow

1. `cloud vm create` claims a clean, single-claim warm machine and creates one
   initial daemon session and remote workspace. Its receipt returns all three
   IDs. Readiness includes the daemon, private route, and guest file grant, so
   the receipt is usable immediately.
2. `cloud agent run --agent claude` starts Claude inside that workspace. The
   guest receives a machine and session lease plus a VM-local model endpoint.
   Managed network identity adds model authority outside the VM. It receives no
   reusable model bearer, host socket, or user refresh token.
3. Claude runs `cmux workspace`, `cmux tab`, `cmux pane`, `cmux open`, `cmux
   diff`, and `cmux markdown` against the VM daemon. Each result is a remote ID
   and a revision. The host reconciler mirrors the result into the dedicated
   local Cloud workspace when attached.
4. Claude runs `cmux browser open http://127.0.0.1:3000`, reads a revisioned
   snapshot, and uses typed click, fill, press, wait, get, and find actions. The
   browser and network run in the VM. The host displays frames and can send
   explicit user input. A request for a Mac path fails before any host API is
   called.
5. Claude moves a remote tab or surface. The VM daemon validates ownership and
   revision, emits a topology event, and the host reconciler moves only the
   matching remote projection. Local tabs remain untouched.
6. The user detaches or the network drops. The VM workspace and viewer state
   remain durable. Reattach replays the cursor or requests a fresh snapshot.
7. A user may explicitly pull a VM artifact to a selected local destination.
   No remote action opens or overwrites a local path.

## CLI design

### Current Rust help gap

The current Rust `cmux --help` already uses noun-first, selector-before-action
paths for workspace, screen, pane, tab, terminal, and browser resources. Keep
that shape. Its current public tree does not yet contain Cloud lifecycle, auth,
teams, projects, VPN, CodeRouter, viewer, diff, Markdown, desktop, process, or
peer scopes. The current browser scope has navigation and raw input, but not
revisioned snapshots or semantic click, fill, wait, query, and state actions.
It also exposes one legacy deployment-authority root that must disappear from
public help and generated metadata.

The migration is complete only when every new root has offline human and JSON
help, maps to one action registry, and works in its documented context. A help
entry without its behavior fixture and owner is not parity.

### Grammar and global options

The canonical grammar is:

~~~text
cmux [global-options] cloud <resource> [selector] <action> [options] [-- argv...]
~~~

The summary form above omits selectors. Actual resource paths use the same
selector-before-action grammar as local cmux:

~~~text
cmux workspace <workspace> show
cmux pane <pane> split

cmux cloud vm <machine> workspace <workspace> show
cmux cloud vm <machine> pane <pane> split
cmux cloud pane <globally-typed-pane-id> split
~~~

The `cloud` prefix changes the graph and transport. It does not create a
second set of workspace, pane, terminal, browser, or process verbs. A typed
Cloud resource ID can omit its ancestors. A name or `current` must include the
complete parent path. Every response includes the canonical full path. An ID
outside the selected team or lease returns the same `resource.not_found` as an
unknown ID, so direct addressing does not become an existence oracle.

Use one verb lexicon:

| Verb | Meaning |
| --- | --- |
| `list` | Read a collection. |
| `show` | Read one resource. `get` is a migration alias only. |
| `create` | Make a durable resource and return its ID. |
| `open` | Present or attach to an existing resource. It does not imply creation unless that command says so. |
| `attach` / `detach` | Add or remove a view or live client without ending the owned resource. |
| `close` | End the named terminal, browser, viewer, session, or other resource. A topology close only detaches its contained views. |
| `destroy` | Irreversibly remove a machine and its dependent resources. |
| `exec` | Run one bounded noninteractive argv and return its exit result. |
| `run` | Start durable work and return resource IDs or route one complete job. |
| `wait` / `watch` | Wait for one terminal state or stream state changes. |
| `cancel` | Request cancellation and return a receipt. |

The existing domain verbs remain an explicit compatibility exception. `rm`
continues to mean publication removal in that namespace.

Aliases are resolved before resource parsing:

~~~text
cmux cloud vm list          # canonical, explicit
cmux vm ls                  # permanent short alias
~~~

Alias resolution is deterministic and happens before option parsing:

| Existing spelling | Canonical action |
| --- | --- |
| `cmux vm ls|list` | `cmux cloud vm list` |
| `cmux vm new|create` | `cmux cloud vm create` |
| `cmux vm ssh|shell|exec|push|pull <machine> ...` | `cmux cloud vm <machine> ssh|shell|exec|push|pull ...` |
| `cmux vm rm|destroy|delete <machine>` | `cmux cloud vm <machine> destroy` |
| `cmux vm terminal send <machine> <terminal> ...` | `cmux cloud vm <machine> terminal <terminal> write ...` |
| `cmux vm terminal read|wait <machine> <terminal> ...` | `cmux cloud vm <machine> terminal <terminal> screen read|wait ...` |
| `cmux vm agent <action>` | `cmux cloud agent <action>` |
| `cmux vm domains <action>` | `cmux cloud domains <action>` |
| `cmux vm route|run` | `cmux cloud vm route|run` |

The result envelope records both the canonical action ID and the spelling the
caller used. This preserves scripts without making help or telemetry maintain
two implementations.

Global options accepted by Cloud commands:

~~~text
--profile <name>
--team <id>
--json | --jsonl | --quiet
--format human|json|jsonl
--timeout <seconds>
--request-id <id>
--idempotency-key <key>
--expected-revision <n>
--yes
--no-open
~~~

Everything after -- is an exact argv array. The client never reads or expands
the caller's shell, and never turns a command into a shell string unless the
user explicitly chooses shell.

Help is local and does not require login, a desktop app, or a socket:

~~~text
cmux cloud --help
cmux cloud vm --help
cmux cloud vm create --help --json
~~~

Help marks each command as headless, desktop, guest, or interactive. An agent
can reject a command that would require a human window.

### Frontend implementation

The Rust CLI is a thin typed frontend over the action contract. Its
execution pipeline is fixed:

~~~text
argv
→ tokenize without shell evaluation
→ resolve canonical noun and compatibility alias
→ parse a typed action and exact selectors
→ load profile, team, deadline, and output policy
→ preflight permission, cost, and confirmation
→ execute through Cloud or remote transport
→ collect operations, events, and verification
→ render one human or machine-readable result
~~~

Each resource module owns its typed command definitions and selector rules.
The top-level dispatcher only resolves aliases and chooses a module. A
CommandContext supplies profile, team, clock, cancellation, transport, and
renderer dependencies. No command reads a singleton, mutates global output
state, or calls the Swift parser.

The schema generates action IDs, option metadata, action preconditions, and
JSON shapes. Human wording and the Ben Swerdlow domain flow remain reviewed
handwritten projections over those generated shapes. This avoids a giant
match statement while also avoiding a generator that invents unsafe UX.

Interactive commands declare their TTY and focus requirements. Headless
commands fail with a typed mode error when they would open a window or take
focus. The same action can expose an interactive projection and a JSON result,
but it cannot silently change side effects between them.

Every atomic action declares its complete effect set. Each command also has
one primary result shape:

| Shape | Required agent behavior |
| --- | --- |
| `result` | Read one bounded object and finish |
| `receipt` | Keep the IDs, revision, and idempotency receipt |
| `operation` | Keep the operation ID, watch or wait, and cancel explicitly |
| `stream` | Read JSONL, retain the cursor, and handle a typed replay gap |
| `interactive` | Hold the input lease, detach, and retain the resume cursor |
| `transfer` | Track direction, digest, byte limit, progress, and final receipt |

Effect sets define authority. Result shapes define control flow. A renderer
cannot change either contract.

### Output, streams, and exit codes

Human output is concise. Progress and routing decisions go to stderr. Stdout
contains only command data, so a successful cloud vm run can be piped safely.

json returns one object. jsonl returns one result, event, or operation
transition per line. Every object includes request_id when a request crossed
the API boundary. quiet suppresses successful output but keeps errors.

| Code | Meaning |
| --- | --- |
| 0 | Success or clean stream completion |
| 1 | Cloud operation rejected, remote command failed, or managed-service failure |
| 2 | Local syntax, selector, profile, or configuration error |
| 3 | Transport, framing, deadline, or protocol failure |
| 4 | Authentication required or refresh failed |

cloud vm run passes through the remote command exit code. cloud vm exec returns 1
for a remote nonzero exit and puts the remote exit_code in JSON. This keeps a
shell command's exit namespace separate from cmux's transport namespace.

### Command tree

The target surface is noun-first:

~~~text
auth status|login|logout
team list|current|use
project list|show|dev|env set|env list|env rm|sync

cloud operation <operation> show|wait|watch|cancel
cloud doctor [--json]

cloud vm list|create
cloud vm <machine> show|status|stats|wait|wake|sleep|rename|destroy
cloud vm base open|reset
cloud vm <machine> snapshot list|create
cloud snapshot <snapshot> show|delete|fork
cloud vm <machine> restore <snapshot>
cloud vm <machine> route|ssh|shell|exec|run|push|pull|dev
cloud vm <machine> repo clone
cloud vm pool list

cloud session list|create
cloud session <session> show|attach|detach|resume|close|events
cloud workspace list|create
cloud workspace <workspace> show|rename|close|delete
cloud workspace <workspace> layout export|apply
cloud screen list|create
cloud screen <screen> show|rename|focus|close
cloud screen <screen> layout export|apply|undo
cloud pane list|create
cloud pane <pane> show|rename|focus|close|split|neighbor|swap|zoom|run
cloud tab list
cloud tab create terminal|browser
cloud tab <tab> show|rename|move|focus|close
cloud surface list
cloud surface <surface> show|open|rename|move|focus|attach|detach
cloud terminal list
cloud terminal <terminal> show|write|keys|move|attach|close
cloud terminal <terminal> screen read|wait
cloud terminal <terminal> resize|signal
cloud process list
cloud process <process> show|wait|events|cancel

cloud agent list|run
cloud agent <run> show|wait|logs|stop|resume|fan-out
cloud agent adapter list|describe|install|remove

cloud network status|peers|routes|connect|disconnect
cloud network grant list|create
cloud network grant <grant> show|revoke
cloud network egress <session> show
cloud network egress <session> set <machine-only|project|internet> [--ttl <duration>] [--domain <suffix>...]
cloud port list|open|close|forward
cloud domains list|zones|verify|publish|access|rm

cloud desktop list|open
cloud desktop <desktop> show|status|snapshot|accessibility|attach|detach
cloud browser list|open
cloud browser <browser> show|navigate|snapshot|screenshot|wait|get|find|is|click|fill|press|select|scroll|viewport|input|attach|close
cloud projection list
cloud projection attach <remote-workspace|resource> [--follow-focus]
cloud projection <projection> move|detach
cloud event stream|read
cloud notification list|read|ack
cloud usage team|machine|agent

# Guest convenience paths, resolved against the signed VM lease
context|tree
peer list
peer <peer> show|resolve|forward|shell|exec|push|pull
peer forward list
peer forward <forward> show|close

coderouter auth|status|session|model|usage|run
coderouter account list|add|enable|disable|remove|clear

vpn status|up|down|revoke|hosts
~~~

Top-level coderouter and vpn remain because they can serve local and Cloud
clients. cloud network reports the Cloud route used by a command. vpn controls
the local machine's system tunnel. They are not aliases. Action checks are
automatic; `cloud doctor` is for diagnosis after a failure, not a setup step.
`cloud projection` is host-side placement of VM-owned resources. It never
projects a host resource into a VM and never exposes a host ID to a Cloud
agent. `--follow-focus` is an explicit host choice for one bounded projection
container. It does not grant Mac focus. Local file sharing, if added later, is
a separate user-only transfer flow and is not a remote agent action.

The `cloud workspace`, `cloud pane`, `cloud terminal`, `cloud browser`, and
`cloud process` direct paths require a globally typed opaque ID. Their nested
forms under `cloud vm <machine>` support names and prove containment. Legacy
Swift action-first paths such as `vm terminal send <machine> <terminal>` map to
the same Rust action during migration and do not define a second grammar.

### Domain command compatibility

The public domain surface is intentionally the same surface already shipped
by Ben Swerdlow's Cloud domain flow. The Rust command and the Swift
compatibility command must accept the same verbs, positionals, aliases, and
defaults:

~~~text
cmux cloud domains [list]
cmux cloud domains zones
cmux cloud domains verify <domain>
cmux cloud domains publish <vm> <port> [--domain <hostname>]
  [--access personal|team|public] [--team <team-id>]
cmux cloud domains access <hostname> <personal|team|public> [--team <team-id>]
cmux cloud domains rm <hostname>
~~~

cmux vm domains is a compatibility spelling. list is the default and has an
ls alias. zones has a custom alias. rm has remove and delete aliases. Do not
introduce a singular cloud domain namespace or a second publication workflow.

The user flow is fixed:

1. list prints active publications. Human output starts with the HTTPS URL,
   then shows publication ID, VM and port, access mode, state, routing
   revision, domain kind, and verification hints. JSON returns stable
   publications data.
2. zones lists custom zones separately from publications. It shows zone
   verification and certificate state, dependent publications, and the
   labelled DNS checklist while either state is incomplete.
3. verify is a zone operation. The normal input is a base zone. For
   compatibility, an owned publication hostname or publication/domain ID may
   resolve to that base zone, but the operation still verifies only the zone.
   The first call creates the ownership challenge and prints labelled
   ownership, routing, and certificate records. The user changes DNS and runs
   the same command again. Verification is attributed by the stored challenge
   ID and base zone, not by an infrastructure domain lookup.
4. publish accepts a VM and port. Without domain it mints a friendly generated
   hostname in the reserved cmux.sh zone and needs no customer DNS proof. The
   generated name is friendly and one label; users cannot choose a label under
   that reserved zone. With domain it accepts the verified base zone or
   one-label child. The preferred
   flow verifies first. If a custom publication is requested before DNS is
   verified, it reserves a provisioning record and the repeated verify command
   completes it; it never creates a serving rule early. It defaults to
   personal access. team requires team ID; public has no forward-auth check.
5. access changes only the publication policy and accepts its hostname as the
   user-facing selector. The existing publication ID remains accepted for
   compatibility. The only modes are personal, team, and public. Current team
   membership is checked on every protected request.
6. rm unpublishes by hostname as the user-facing selector. The existing
   publication ID remains accepted for compatibility. It disables
   authorization, removes the exact edge rule, and then removes the local
   record. It is safe to retry.

The DNS checklist labels why each record exists. It includes the ownership TXT
record, apex and wildcard routing records, and the _acme-challenge delegation.
When a DNS service lacks ALIAS, ANAME, or flattening, the output gives the
same www redirect fallback. The access page has only sign-in and denial
states; it does not add request-access or viewer-grant flows. These details
are part of the contract, not presentation-only choices.

### Selectors and confirmation

Selectors accept an opaque ID, an exact name, or current only when the
command has an unambiguous caller context. name:value forces name
interpretation for names that resemble IDs or command words. Every response
echoes the resolved ID, display name, team, and machine.

Destructive commands require an interactive confirmation, yes in an explicit
noninteractive policy, or a server-issued confirmation token when a preview
found dependent resources. yes never bypasses authorization, revision fences,
billing gates, or publication cleanup.

The established cloud domains rm hostname command is the compatibility
exception: it keeps its current one-command behavior and does not add a
surprise prompt. It still requires ownership, an exact hostname or publication
ID, revision and idempotency checks, and complete edge cleanup. A future
breaking CLI version may add an explicit confirmation mode after migration
metrics show that callers can handle it.

### SSH, exec, run, and terminal control

| Verb | Contract |
| --- | --- |
| cloud vm <id> ssh | Interactive shell. Prefer cmux-remote; use OpenSSH only when transport openssh is explicit or the daemon is unavailable. The fallback disables agent forwarding and host keychain access unless a local user selects an isolated key. |
| cloud vm <id> exec -- <argv> | One noninteractive direct process, bounded output, structured exit result, no stdin. |
| cloud vm run [--machine <id>] -- <argv> | Route a fresh command by project or work key, optionally sync and pull, then return the remote exit code. `cloud vm <id> run` pins it. |
| cloud terminal <terminal> write, screen read, or screen wait | Drive an existing PTY without creating a pane or taking focus. |
| cloud vm <id> push or pull | Resumable, digest-verified transfer with exclusions and size limits. Push is explicit host-to-VM input; pull is explicit VM-to-host output and never auto-opens or overwrites a host path. |
| cloud vm <id> repo clone | Clone in the VM so large repositories and credentials do not cross the laptop. |

ssh is an experience and compatibility verb, not the security model. Machine
identity, remote enrollment, and grants decide authority.

## Cloud action areas

### Machine lifecycle, bases, snapshots, and forks

The base machine is one pinned persistent machine for ongoing work. Pool
machines are router-owned and may be drafted by cloud vm run or cloud agent.
A user-created machine is never drafted because its label says agent-pool;
membership uses a durable server or local binding ID.

Create is a fast claim operation. The backend keeps clean, single-claim warm
machines by region, size, and image family. A create request atomically claims
one, assigns its first tenant machine identity, and returns as soon as the
daemon-ready probe succeeds. The warm path targets p50 under 3 seconds and p95
under 10 seconds. The command waits for a ready machine by default. If the warm
pool is empty, the API returns an operation immediately and the Rust client
follows it to readiness with progress and a bounded deadline. `--no-wait`
returns the operation instead. The response always includes the machine,
initial daemon session, and initial workspace IDs, state, operation ID when
present, and the next safe command.

A warm machine is booted from the pinned immutable image and has never had a
tenant. It contains no user disk, files, credentials, routes, publications, or
event cursors. It waits in a fenced parked state with no tenant network or
reusable daemon identity. Refill records image provenance and a clean-state
attestation before a slot becomes claimable. Claim assigns the first tenant
generation and daemon identity. A released or destroyed tenant machine is
destroyed and never returns to the pool. A failed readiness or attestation
probe, unexpected disk, stale route, or stale identity discards the slot and
retries only with a bounded budget. Create does not perform a separate
action-list round-trip; the requested kind, size, region, and image family are
validated in the same action.

The warm-pool key includes the persistence profile. A persistent machine claims
an unused encrypted home-volume lease from the warm storage pool before the
daemon-ready probe; a volume that is not clean or cannot mount is not a warm
slot. Readiness therefore covers the home mount, daemon, private route, and
requested machine kind, not only the host boot state.

Warm-pool refill creates replacement instances asynchronously and never sits
on the create request. The claim transaction locks one slot and cannot return
the same slot to two callers. Concurrent claims either receive distinct slots
or take the cold-operation path; they never queue behind a generic catalog or
capability request. Single-claim slots increase idle compute cost and remove
the cross-tenant erasure claim that an in-place recycle would require.

The pool controller sizes each region, size, image-family, and persistence cell
from recent arrival rate and the p95 refill time. It keeps a small reserve for
bursts and caps idle cost. Metrics separate queue, claim, identity rotation,
storage mount, route, daemon, and first-workspace time. A fast total with a slow
hidden stage does not meet the target.

The create request carries the display label, when supplied, in the same
idempotent transaction. It does not create the machine and then issue a second
rename request on the fast path. A legacy backend may apply the label through
one fenced compatibility update, but the Rust facade reports that extra step
in the receipt.

The result is ready-or-operation, with one stable shape:

~~~json
{
  "machine": {"id": "vm_01...", "state": "ready"},
  "session": {"id": "session_01..."},
  "workspace": {"id": "ws_01..."},
  "operation": null,
  "ready": true,
  "next_actions": [
    "cmux cloud session session_01... attach",
    "cmux cloud vm vm_01... ssh"
  ]
}
~~~

For a cold claim, `operation` identifies the durable create and `ready` is
false. The Rust client follows it by default, writes progress to stderr, and
prints one final receipt to stdout. `--no-wait` returns the same operation
without opening a local terminal. `--timeout` changes the default ten-minute
follow deadline. `--detach` only controls the local terminal projection after
readiness; it never changes machine ownership or lifecycle.

Snapshots are immutable checkpoints. A fork records the source snapshot and a
new machine ID. Restore checks image and daemon requirements, freezes
dependent publications and sessions, and returns a receipt describing what was
preserved and what was intentionally not preserved. Running processes are not
promised to survive a daemon restart; their durable exit or interruption
receipt is the truth.

### Project environments

cloud vm dev makes a directory reproducible in one machine workspace:

1. route by an explicit work key, otherwise repository and branch, otherwise
   the caller directory hash;
2. sync with digest-aware transfer or clone in the VM;
3. detect lockfiles, toolchain files, or devcontainer.json;
4. record a reviewable .cmux/cloud.json recipe;
5. replay only changed setup steps;
6. create or reuse a named workspace;
7. run bounded checks in a durable terminal;
8. return the workspace, operation, and verification receipt.

The manifest contains commands, lockfile hashes, named secret references,
services, checks, ports, image requirements, and agent defaults. Secret values
are stored per user and project in the control plane. A fork may reuse setup
only when image and lockfile digests match.

### Sessions, topology, and layouts

One machine may contain many workspaces. A workspace may contain many
terminals, and a terminal may be projected into more than one local pane.
Closing a pane detaches a projection; it does not kill the remote process.
Closing a terminal is the explicit process lifecycle action.

The machine catalog and desktop sidebar are projections of the same resource
graph. cloud workspace layout export and apply operate on a portable layout
document containing remote workspace, terminal, split, tab, and ratio data. It
cannot contain a local socket, local surface ID, or executable secret.

Reconnect uses cmux-remote lane cursors and structured terminal snapshots.
When a replay cursor is too old, the client requests a new snapshot and
resubscribes. It never replays raw bytes from an arbitrary offset.

### Private networking, ports, and domains

There are three network paths:

1. System VPN: cmux vpn up installs host-to-VM routes for Safari, OpenSSH,
   curl, and other operating-system traffic. It may require root or
   NetworkExtension. The packet tunnel admits VM packets only when they match a
   connection that the Mac started. It does not advertise a Mac route or
   service.
2. Userspace link: cloud session attach can use cmux-wg without root or a VPN
   prompt. It carries only cmux's authenticated link. A local egress broker
   shares one app tunnel across sidecars; it has no VM-reachable listener. iOS
   holds one in-process tunnel with the same one-way initiation rule.
3. Public publication: a port is exposed through the managed TLS edge with a
   generated or verified custom hostname and an explicit access policy.

Public custom-domain publication is a managed-edge action. The Rust client
validates the requested zone, access mode, and machine route in the publish
action. An environment without the TLS publication contract returns a typed
`action_unsupported` result; it must not silently switch infrastructure or
expose an opaque deployment URL as if it were a cmux domain.

cloud vm port open returns a private, tokened endpoint and records protocol,
bind, owner, and reachability state. It does not create an arbitrary public
proxy. Loopback listeners are not advertised as reachable until a probe proves
the selected bind is valid.

Internal names such as machine.internal are private DNS entries maintained by
the selected tunnel profile. Public domains are a different resource:

~~~text
cloud domains verify example.com
cloud domains publish <machine> 3000 --domain app.example.com --access team
cloud domains access app.example.com public
cloud domains rm app.example.com
~~~

The backend owns DNS challenges, TLS certificates, edge rules, and private
keys. A publication has exactly one access mode: personal, team, or public.
Changing the mode is an ordered state transition, and deleting a VM first
disables and sweeps every dependent publication.

Machine-to-machine application routes use declared same-project services and
exact peer grants. A strong grant names source, destination, action, service or
endpoint, and expiry. It is not inferred from shared team membership. `cloud
network` changes Cloud routes only. `vpn up|down` changes the host
operating-system route table and is host-user-only. A VM cannot install,
remove, or widen a host route.

`cloud vm ssh` uses cmux-remote first. Its OpenSSH fallback disables agent
forwarding and host keychain access unless a local user explicitly selects an
isolated key. `cloud vm port forward` binds a loopback port on the host by
default, never a public interface, and does not auto-open a host browser. A
remote VM cannot turn a forward into a reverse connection to a host service.

### Agents and CodeRouter

Compute and model credentials are separate resources:

- the machine and workspace provide compute and durable process ownership;
- CodeRouter supplies a model route and usage attribution;
- an agent adapter translates a native CLI into cmux lifecycle events.

Cloud create provisions a VM-local model endpoint. The managed edge verifies
source machine and session identity and adds short-lived model authority
outside guest control. No reusable bearer enters the image, process
environment, or config. VM root can use the machine allowance and read its own
usage. It cannot replay that authority from another machine or manage team
accounts or Cloud lifecycle. Agent launch also sets the guest cmux context and
removes host socket, host filesystem, clipboard, keychain, and SSH-agent
variables.

Rust CodeRouter commands manage:

~~~text
coderouter status
coderouter auth login|status|logout
coderouter session open|close|status
coderouter usage team|machine|agent
coderouter account list|add|enable|disable|remove|clear
coderouter model list
coderouter run <agent> -- <args>
~~~

Credential intake is from a platform keyring, an explicitly named environment
variable, hidden terminal input, or stdin. Credentials never arrive in argv.
Account selectors are IDs, exact labels, or masked identifiers, with ambiguity
rejected.

Agent adapters are declarative manifests. Each declares stable agent ID and
binary detection, launch/resume/stop/session-ID extraction, hook installation,
native-event mapping, required runtime conditions and permissions, and safe
transcript sources. Each manifest also declares that its process scope is the
leased VM workspace and lists forbidden host resources. Claude, Codex, OpenCode,
and Pi are adapter fixtures, not hardcoded branches in the Cloud transport.

The semantic event set is:

~~~text
agent.session.started
agent.turn.started
agent.turn.completed
agent.approval.requested
agent.question.requested
agent.plan_review.requested
agent.error.reported
agent.state.changed
~~~

blocked is derived from unresolved approval, question, plan review, or explicit
needs_input. It is not the primary event.

### CodeRouter package and namespace reuse

`coderouter` and `cmux coderouter` are two command frontends over one model-plane
contract and command engine. They do not share a binary, config file, or
keyring entry. They share their noun-action grammar, help, validation, action
IDs, wire models, error codes, retry rules, renderers, redaction, and behavior
fixtures.

The reusable public layers are:

| Layer | Responsibility | Must not own |
| --- | --- | --- |
| `coderouter-contract` | Versioned JSON Schema, action definitions, redaction annotations, and generated TypeScript package | credentials, transport, or process state |
| `coderouter-protocol` | Generated Rust request, response, error, usage, and session types | HTTP, filesystem, or global state |
| `coderouter-client` | Async transport-neutral client, auth traits, team scope, account/session/usage actions, deadlines, retries, idempotency, and redaction | TTY rendering, keyrings, config files, or process spawning |
| `coderouter-handoff` | VM-local endpoint configuration, environment scrubbing, and agent invocation plans | VM lifecycle, PTYs, portable guest credentials, or agent process ownership |
| `coderouter-command` | Reusable parser fragment, command validation and dispatch, normalized results, help, and human, JSON, and JSONL renderers | top-level binary selection, keyrings, config paths, terminal selection, or process ownership |

These layers should live in a small public `coderouter-core` repository and be
released as independently versioned artifacts. A public repository is required
because the cmux source and build must remain reproducible. The standalone
CodeRouter npm package is a native-binary launcher, not a JavaScript library;
cmux must not import it or download it at runtime. The standalone source may
remain private because the shared contract and client contain the reusable
surface without product secrets.

The dependency graph is:

~~~text
coderouter-contract
        ↓
coderouter-protocol
        ↓
coderouter-client  ── coderouter-handoff
        ↓                 ↓
        coderouter-command
              ↙       ↘
        coderouter   cmux coderouter
~~~

The standalone frontend owns its keyring, config, TTY, and local process
adapter. The cmux frontend owns its Cloud profile, team and session context,
and local or remote process adapter. The command tree after the optional
`cmux` prefix is identical. Both map their verbs to the same action IDs:

| Standalone | cmux | Action ID |
| --- | --- | --- |
| `coderouter auth login` | `cmux coderouter auth login` (alias: `cmux auth login`) | `auth.session.open` |
| `coderouter status` | `cmux coderouter status` | `coderouter.status` |
| `coderouter account list` | `cmux coderouter account list` | `coderouter.account.list` |
| `coderouter account add|remove|enable|disable` | `cmux coderouter account add|remove|enable|disable` | `coderouter.account.mutate` |
| `coderouter session open|close|status` | `cmux coderouter session open|close|status` | `coderouter.session.mutate` or `coderouter.session.get` |
| `coderouter model list` | `cmux coderouter model list` | `coderouter.model.list` |
| `coderouter usage team|machine|agent` | `cmux coderouter usage team|machine|agent` | `coderouter.usage.get` |
| `coderouter run <agent>` | `cmux coderouter run <agent>` | `coderouter.session.open` |

Existing standalone `accounts`, `add`, and direct agent spellings, plus
`cmux coderouter machines` and `cmux coderouter claude ...`, stay as aliases
while callers migrate. `cmux cloud agent run --agent <agent>` composes machine
selection with the same `coderouter run` action. It is not a CodeRouter alias.
The final Rust namespace does not search `PATH` or silently spawn a second
executable. A one-release compatibility flag may invoke the installed binary
only when explicitly requested, and it must label the result, preserve the
exit code, and report the contract mismatch.

Authentication uses injected traits. cmux stores its Cloud profile in the cmux
keyring; standalone CodeRouter stores its own profile in a namespaced entry.
Neither product copies refresh tokens into the other config. If a user links
the accounts, the service performs a one-time scoped exchange and returns a
new token with only model-plane permissions. Team selection is explicit in
every team-scoped request.

The shared client and command engine are asynchronous. The standalone binary
uses a small blocking entry adapter, while cmux uses its existing async runtime.
This costs two entry adapters and prevents model work from stalling remote
terminal or event work. Human text, JSON, and JSONL render the same result
envelope, which includes `contract_version`, `action_id`, `request_id`, and
redaction metadata.

CodeRouter never owns machine creation, snapshots, networking, or terminal
processes. `cmux cloud agent run` composes a machine action, a remote session,
the handoff plan, and a model route. This boundary prevents a model credential
from gaining compute authority and lets either frontend reuse the model plane.

### Desktop, browser, notifications, and mobile

Desktop machines expose a VNC/noVNC display as a resource outside a terminal
workspace. Browser surfaces and forwarded ports use the same remote
`surface.project` operation as terminals. The CLI can inspect and control them
headlessly when the machine response reports `desktop_ready` or
`browser_ready` for that specific action. This applies only to a browser owned
by that Cloud machine.

The user-facing split is explicit:

~~~text
cmux cloud session <session> attach --workspace <local-workspace>
cmux cloud projection <projection> move --workspace <local-workspace>
cmux cloud vm <machine> browser open <url>   # browser process in the VM
~~~

Attach creates a local Cloud projection workspace containing only remote
resources. `cmux open`, `cmux diff`, and `cmux markdown` invoked in a VM resolve
VM paths and send safe snapshots to that projection. The host pane displays
remote browser frames and sends explicit user input to the VM browser. It never
loads the URL in a host WebView. Host file URLs, host cookies, host clipboard,
host accessibility state, host paths, and host browser control are not part of
the Cloud agent contract.

Notifications are durable machine events. An agent can emit cmux notify inside
a VM without a Mac attached. A reconnecting client drains by cursor and
acknowledges after rendering. Later, the control plane may fan out the same
ledger to iOS push; push is a delivery adapter, not a second event source.

Mobile and desktop clients use the same Cloud resource IDs and action-specific
state responses. The iOS FFI client is a data-plane client; VM lifecycle and billing
remain in the Rust Cloud client and backend.

### Usage, billing, and policy

Every billable or quota-relevant action returns a usage reference and request
ID. The usage ledger records resource IDs, deployment image, agent, model
category, status, and token or machine-time counts. It never records prompts,
outputs, raw commands, credentials, or terminal bytes.

Plan limits, free windows, machine counts, service budgets, and team
membership are server decisions. The CLI may display a preflight estimate, but
it cannot enforce policy by deleting a machine or guessing a plan.

## Agent-accretive extension contract

### Action metadata and extensions

An action descriptor is data:

~~~json
{
  "id": "cloud.vm.exec",
  "title": "Run a command in a Cloud machine",
  "contexts": ["machine.ready", "auth.team_selected"],
  "inputs": [
    {"name": "machine", "type": "machine.selector", "required": true},
    {"name": "argv", "type": "argv", "required": true}
  ],
  "preconditions": ["machine.ready", "permission.machine.exec"],
  "permissions": ["machine.exec"],
  "effects": ["process.created", "usage.recorded"],
  "observes": ["operation.progress", "process.exit"],
  "verification": ["process.exit.code"],
  "limits": {"output_bytes": 4194304, "deadline_seconds": 30}
}
~~~

An agent normally receives this descriptor with command help or an action
failure. It does not need a discovery request before invoking a known action. A
human can inspect and approve the same descriptor in the sidebar or
command palette. External additions are valid only when they use this schema
and declare their permissions.

The descriptor is not a security oracle. The daemon has an independent rule
that guest actions cannot name a host selector, request a host effect, or enter
the Cloud control plane. The projection parser accepts a separate small event
schema. The managed network evaluates identity and grants independently. This
small duplication prevents one bad descriptor from widening every boundary.

### Project and adapter manifests

.cmux/cloud.json is a project-owned recipe, not an executable hook. It may
name commands and secret references, but cannot contain a token, arbitrary
infrastructure API call, or local surface ID. Agent manifests follow the same
rule.

Initial extension points:

- agent adapters;
- project environment recipes;
- portable layouts;
- browser and verification actions;
- notification and event consumers;
- link handlers and runbooks.

The core does not accept arbitrary plugin code in the remote daemon. A trusted
adapter may request a declared action; the server still checks principal,
action preconditions, revision, and resource ownership.
Project and adapter manifests can instantiate registered actions. They cannot
declare a new effect, permission, selector type, or guest command.

### Verification receipts

Every composite command returns:

~~~text
decision: selected machine and reason
plan: ordered actions and their idempotency keys
operations: operation IDs and final states
resources: stable IDs created or reused
verification: checks, observed values, and timestamps
next_actions: safe follow-up commands
~~~

Human output may summarize this. JSON and JSONL retain it. This lets another
agent continue without reconstructing hidden state.

## Packaging and release

| Distribution | Contents | Required property |
| --- | --- | --- |
| npm cmux | platform launcher plus matching Rust binary | clean install, checksum and executable-bit verification |
| PyPI cmux | platform wheel plus matching Rust binary | uvx cmux works without Bun or a desktop app |
| npm/PyPI coderouter | standalone native launcher plus matching binary | independent release stream, checksum verification, and no cmux dependency |
| CodeRouter core artifacts | public schema, generated Rust protocol, async client, and handoff library | both frontends use the same action IDs and fixture suite |
| Desktop app | existing bundled Rust binary and Swift projection | one binary version for local, Cloud, and remote commands |
| VM image | pinned Linux binary, daemon supervisor, common tools, adapters | readiness and action-specific state before attach |
| SDK/FFI | generated models and narrow data-plane bindings | version negotiation and no hidden singleton state |

Cloud code is measured from a release build after the client lands. The
desktop app must not carry a second copy of the binary. npm and PyPI launchers
must reject a binary with a mismatched protocol or image manifest.
CodeRouter and cmux may release on different schedules, but their shared
contract version must be supported by both before either frontend publishes a
new action. Release artifacts include checksums, provenance, SBOM, and a
rollback channel.

The clean-install matrix covers Linux x64 and arm64, macOS arm64 and x64,
Windows x64, no desktop app, no Bun, offline help, login, VM list, create,
attach, exec, reconnect, CodeRouter status, and logout.

## Delivery principles

Implementation is vertical. Each slice includes the schema, backend mapping,
Rust command, compatibility bridge, behavior tests, and one clean-package
acceptance path. Do not land a Rust parser that only prints a future help
screen.

The first complete path is:

~~~text
clean npm/PyPI install
→ auth login
→ team use
→ cloud vm list
→ cloud vm create
→ cloud vm <machine> ssh or exec
→ cloud session <session> attach
→ cloud agent run through CodeRouter
→ cloud domains verify example.com
→ cloud domains publish <vm> 3000 --domain app.example.com --access team
→ verify the published URL and access policy
→ disconnect and resume
→ snapshot
→ cloud vm <machine> destroy
~~~

Project manifests, desktop surfaces, machine-to-machine links, and fan-out are
separate action slices after this path has a reliable receipt and replay story.
Public custom-domain publication is part of the first release, not a later
parity promise. An environment may gate an access mode, but it must expose the
typed zone, TLS, publication, health, and cleanup workflow from the first
release.

The automated clean-install path uses a generated cmux.sh hostname. A separate
live smoke uses a customer zone and exercises the DNS checklist, repeated
verify call, wildcard certificate readiness, protected access, public access,
and unpublish cleanup. This keeps release automation deterministic while still
making custom domains a release requirement.

## Rejected shortcuts

- Swift as the permanent Cloud owner duplicates Rust's resource and error
  model and keeps headless packages dependent on a Mac.
- Rust shelling Swift preserves the duplicate contract and makes Linux and
  Windows impossible.
- Infrastructure SDKs in Rust clients leak deployment semantics and
  credentials; backend adapters are the single infrastructure boundary.
- SSH as the only transport loses structured replay, process catalogs, bounded
  action checks, and userspace mobile links.
- One VM per agent task wastes warm state. Use many workspaces in one machine,
  then fork for isolation.
- Polling as the event model burns resources and loses durable ordering. Use
  cursors, bounded replay, and explicit gaps.
- Public port equals public URL. A private port preview and a verified TLS
  publication have different access and cleanup rules.
- Credentials in the image create account-wide compromise from one guest. Use
  scoped edge injection and short-lived machine principals.
- Forwarding the host cmux socket or a generic `host.rpc` turns a remote agent
  into a local process. Use a typed broker with VM-owned resource IDs only.
- Loading a remote URL in a host WebView lets redirects, scripts, cookies, and
  DNS rebinding cross the boundary. Render a VM browser stream instead.
- Using a host path as a remote file selector leaks the host filesystem. Resolve
  file, diff, and Markdown paths in the VM and send bounded snapshots.
- Treating VPC reachability as cmux authority lets one VM control another.
  Network reachability and daemon grants must remain separate.
- A marketplace before an action schema produces scripts, not composable
  agent actions.

The main residual risk is contract breadth. The implementation plan keeps the
first release narrow while freezing resource, error, action, and receipt shapes
early enough for later clients to accumulate value.

The secure 80/20 vertical slice is one fast machine, one scoped workspace
lease, remote topology and terminal control, VM file/diff/Markdown snapshots,
VM browser snapshots and semantic input, declared same-project services plus
exact peer grants, automatic local projection,
and public domain publication for a VM port. It deliberately rejects host
paths, host-browser control, host socket access, recursive host mounts,
mixed-layout remote control, and implicit clipboard or download transfers.

## Acceptance and evidence

The design is complete only when these behavior-level checks pass:

1. clean npm and PyPI installs run offline help without the desktop app;
2. one authenticated profile cannot read or mutate another team's machine;
3. retried create, restore, publish, and destroy do not duplicate effects;
4. a warm machine reaches daemon readiness within the creation latency target;
   a cold machine returns an operation immediately and can be followed with
   `--wait`;
5. exec, interactive ssh, and existing-terminal control have distinct output
   and exit contracts;
6. a dropped link resumes from a cursor or returns a typed replay gap followed
   by a snapshot, without spawning a replacement shell;
7. CodeRouter requests from Claude, Codex, OpenCode, and Pi are attributed to
   the correct machine and team without a guest-held route token;
8. standalone `coderouter` and `cmux coderouter` produce the same action IDs,
   JSON envelopes, error codes, and usage fixtures, while retaining separate
   keyring and TTY frontends;
9. a verified custom domain can publish a selected machine port, report TLS
   and health state, enforce personal, team, or public access, and be removed
   without leaving a route;
10. private internal access, userspace links, and public TLS domains cannot
   cross their declared policy boundaries;
11. a closed laptop can receive a durable event and a later client can drain and
   acknowledge it;
12. a lease-scoped guest command can enumerate and mutate only resources in its
   workspace closure, and it never receives a host resource ID;
13. a remote `surface.move`, `surface.detach`, and layout action cannot affect a
   local workspace or a resource owned by another machine;
14. `cmux open`, `cmux diff`, and `cmux markdown` in a VM reject traversal and
   symlink escapes, return bounded snapshots, and render active content inertly;
15. a VM browser resolves `file:` only inside its project grant, allows only its
   own loopback and interface addresses plus declared or granted peer services, and blocks
   the host gateway, LAN, metadata, redirects, subresources, WebSockets, WebRTC,
   and DNS rebinding;
16. the host displays a VM browser stream without loading its URL in a host
   browser and without returning host cookies, DOM, pixels, paths, or clipboard;
17. revoking a session or destroying a machine invalidates projection bindings,
   input leases, browser streams, viewers, transfers, and peer grants;
18. the final JSON receipt explains what happened without exposing secrets;
19. VM root can control its project trust domain, but it cannot reach the Mac,
   an ungranted peer, another project, or Cloud administration;
20. a topology close detaches a resource without ending it, while terminal,
   browser, and viewer close return explicit lifecycle receipts;
21. VM root can use its machine model allowance, but it cannot read or replay a
   reusable model bearer from another machine or network identity;
22. every projected surface keeps host-owned machine and project identity and
   cannot use host autofill, password managers, clipboard, drag and drop,
   automatic audio, or global input;
23. browser snapshot references expire on document revision, and semantic,
   pointer, JavaScript, and download actions stay in the VM under one network
   policy.
