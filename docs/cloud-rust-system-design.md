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
- [Implementation plan](../plans/feat-cloud-rust-cli/DESIGN.md)

## Outcome

The target user experience is one command contract available from a clean npm
or PyPI install, the desktop app, a Linux or Windows shell, and a Cloud VM.
The desktop app improves projection and human inspection, but it is not
required for Cloud control or a headless agent run.

An agent must be able to:

1. discover account, team, project, machine, session, network, and agent
   capabilities without reading prose;
2. choose a safe action from typed preconditions, permissions, cost, and
   side-effect metadata;
3. invoke it with stable IDs and idempotent retries;
4. observe progress, events, logs, and a durable result after disconnecting;
5. verify the result with a bounded, machine-readable check.

The product primitive is a capability and lifecycle contract. The TUI, sidebar,
Swift app, npm launcher, PyPI launcher, and third-party adapters are clients of
that contract.

## Decisions

| Decision | Choice | Expert objection and response |
| --- | --- | --- |
| Cloud implementation owner | Rust owns the Cloud client, command behavior, models, errors, auth, and retries. Swift becomes a desktop projection layer and temporary compatibility bridge. | A fast wrapper that launches Swift or launches Rust from Swift leaves two parsers and two error contracts. That is cheaper for one release and expensive for every later feature, so it is not the final architecture. |
| Public namespace | cloud resource action is canonical. vm and cloud vm are compatibility and ergonomic aliases for the machine resource. | One short vm namespace is easier to type, but it hides domains, teams, networks, and operations. The full namespace keeps discovery coherent while preserving existing scripts. |
| Cloud object name | The server object is a machine; vm is its user-facing alias. | Renaming existing IDs would break scripts. IDs stay unchanged, and only the noun has a canonical spelling. |
| Control plane | Rust calls a versioned cmux Cloud API directly over HTTPS. The API remains backed by Vercel routes, Effect services, Postgres, and provider adapters. | Making the app socket the only API blocks npm, PyPI, Linux, Windows, and guest workflows. Making clients call Freestyle directly leaks provider policy and credentials. |
| Data plane | Live terminals, workspaces, processes, events, and computer-use traffic use cmux-remote and its negotiated transports. | Rebuilding the data protocol in the HTTP client creates a second session implementation and loses replay and reconnect guarantees. |
| Network access | System WireGuard, userspace WireGuard, public port publication, and machine-to-machine grants are separate capabilities. | Calling all of them VPN or treating a public URL as a tunnel makes security and failure states ambiguous. |
| OS integration | Rust owns tunnel protocol, route policy, grants, and userspace WireGuard. Small native adapters call macOS NetworkExtension and platform keyring APIs. | Forcing privileged OS APIs into Rust would add unsafe FFI or a root helper. Keeping broad Cloud behavior in Swift would preserve the split. The native boundary is limited to OS facilities and has no Cloud policy. |
| Team scope | Login identifies a person. A selected team is explicit, persisted, and shown in every team-scoped mutation. | Inferring a team from the last response is convenient until a user has two teams. Silent cross-team mutations are unacceptable. |
| Long work | Mutations return an operation receipt when they can outlive one HTTP request. wait, watch, and cancel operate on that receipt. | A synchronous create endpoint is simple until a provider resumes a sleeping machine or Vercel reaches its duration limit. Hidden background work is harder to recover than an explicit operation. |
| Extensibility | Adapters and action manifests extend the capability catalog. They cannot add unaudited control-plane authority. | A marketplace of arbitrary scripts is not a contract. It makes permissions and replay impossible to reason about. |
| Distribution | The desktop app reuses the already bundled Rust binary. npm and PyPI launch the same versioned binaries. | Shipping a second Cloud binary increases size and creates version skew. The current universal client is about 56 MB arm64 plus 59 MB x86_64, about 115 MB before Cloud code is measured. |
| First Cloud release | Public custom-domain publication is included, behind verified zones, TLS state, access policy, health checks, and cleanup. | Deferring domains leaves the main production workflow dependent on provider-specific URLs and leaves the public/private boundary untested. Shipping an unverified or policy-free URL would be worse, so the gate is the complete publication lifecycle, not a port alias. |
| Established domain deletion UX | Keep domains rm hostname as a single command with the existing aliases and output. Enforce exact owner, hostname, revision, idempotency, and provider cleanup in the backend. | A confirmation prompt would reduce accidental deletion, but it would break the shipped Ben Swerdlow flow and scripts. The exact-host and owner fences contain that risk; a new prompt needs a versioned UX decision, not a silent Rust change. |

These choices trade a larger first contract for one source of truth. The
residual risk is migration complexity while Swift and Rust coexist. The plan
limits that period and makes the compatibility boundary observable.

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
| Account | Stack user identity | signed out, signed in, revoked |
| Team | Stack team ID | selected, membership changed |
| Project | server project ID with a repository binding | discovered, configured, archived |
| Machine | opaque server machine ID; display name is not identity | provisioning, ready, sleeping, waking, failed, destroyed |
| Workspace | opaque daemon workspace ID, scoped to a machine | open, closed, recoverable |
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

Every mutable resource has a server revision. Mutations may include
expected_revision; a stale value returns revision_conflict without a partial
effect. A response includes the new revision or an operation whose result will
include it.

### Two planes and one composition root

~~~text
CLI / SDK / Swift projection
          │
          ├── cmux-cloud-client ── HTTPS cmux Cloud API ── Postgres + providers
          │                              │
          │                              └── operations, auth, billing, policy
          │
          └── cmux-remote client ── WireGuard / Iroh / relay ── cmux-tui daemon
                                          │
                                          └── workspaces, PTYs, agents, events
~~~

The control plane decides who may act, which machine is selected, what a
provider can do, and how a mutation is billed. The data plane carries live
terminal and event traffic after the control plane has issued a scoped route.
The planes share resource IDs and request tracing, but neither substitutes for
the other.

Rust crate ownership:

| Layer | Initial owner | Boundary |
| --- | --- | --- |
| Wire models and schema | cmux-cloud-protocol, new | serde models, JSON Schema, capability and error enums; no I/O |
| Cloud API client | cmux-cloud-client, new | HTTPS, auth provider, team context, retries, idempotency, operation polling |
| Public command frontend | cmux-tui Cloud command module | argv, help, output, exit codes, stdin and terminal policy |
| Live remote transport | cmux-remote | enrollment, Noise identity, replay, sessions, terminal and event streams |
| Private link | cmux-wg | userspace WireGuard and dialer; no Cloud policy |
| Embedded terminal view | cmux-terminal-client | small FFI surface for iOS and future embedded clients |
| Desktop composition | Swift app | construct clients, project resources into panes, human approval, local OS integration |
| Backend | web/app/api, web/services/vms, CodeRouter services | auth, policy, billing, provider calls, DNS, TLS, durable state |
| Guest | baked cmux-tui daemon and signed adapters | terminal ownership, local process execution, bounded event production |

The executable app remains the composition root for Swift objects. Rust
libraries receive explicit clients, clocks, stores, and transports. No new
package relies on a singleton or the user's default filesystem.

## Cloud API contract

### Versioning and generated models

The public Cloud contract is cmux.cloud/v1. Existing /api/vm/*,
/api/coderouter/*, and /api/vm/tunnel routes remain compatibility routes while
the versioned client facade is introduced. They map to the same backend
services and database rows, not to a second state store.

The contract source is a checked-in, versioned schema package owned jointly by
the Rust and web teams. Backend route definitions implement that package;
they are not an implicit contract generator. CI must:

1. generate Rust and TypeScript models and the capability catalog;
2. compile the Rust client against the generated models;
3. run fixture conformance for every request, response, capability, and error;
4. reject a breaking change unless the API version changes or an explicit
   compatibility record exists.

Hand-written Swift dictionaries and provider response types are not a
contract. The Swift bridge decodes the generated wire shape during migration.

### Request envelope

Every Cloud request carries:

| Field or header | Purpose |
| --- | --- |
| API version | Rejects unsupported clients before a mutation |
| authenticated principal | Stack user token, or a narrower machine principal |
| team ID | Explicit team context when the resource is team-scoped |
| client ID and version | Package, desktop, guest, or embedded client identity |
| client request ID | UUID allocated before network work, used in logs and support |
| trace context | Joins Vercel, provider, CodeRouter, and client timing |
| idempotency key | Required for every mutation and stable across safe retries |
| expected revision | Optional optimistic concurrency fence |
| deadline | Absolute deadline, never an unbounded phase timeout |

Tokens, credentials, request bodies, and terminal bytes are never put in a
client request ID, trace attribute, URL query, or diagnostic message.

### Response and errors

Successful responses have a common outer shape:

~~~json
{
  "api_version": "cmux.cloud/v1",
  "request_id": "req_01...",
  "trace_id": "trace_01...",
  "revision": 42,
  "capabilities": ["machine.exec.v1", "machine.remote.v1"],
  "data": {}
}
~~~

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
agents. Provider error text is retained only in redacted operator telemetry.
The client maps transport failures, auth expiry, rate limits, revision
conflicts, capability gaps, provider failures, and indeterminate effects to
stable codes.

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
cmux cloud operation get <id>
cmux cloud operation wait <id> [--timeout <seconds>]
cmux cloud operation watch <id>
cmux cloud operation cancel <id>
~~~

Cancellation is cooperative. A canceled request receives a durable tombstone,
and a late provider callback cannot resurrect the resource or overwrite a
newer revision. Cleanup is idempotent and runs after the caller exits.

### Capabilities

Capabilities are returned at account, team, machine, daemon, and transport
boundaries. A capability has a version, requirements, permissions, limits,
and an optional fallback. Unknown capabilities are ignored. A client never
sends a gated request unless the matching capability was accepted for the
current generation.

The CLI presents the same catalog through:

~~~text
cmux cloud capabilities [--json]
cmux cloud describe <resource-or-action> [--json]
~~~

Negotiation covers provider image shape, desktop availability, snapshot and
fork support, private networking, userspace WireGuard, public publication,
CodeRouter agent families, PTY and browser support, file limits, and protocol
versions. It replaces brittle client version checks.

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
and device identity, but never a provider secret. The active profile is
explicit in JSON and can be selected with profile. Commands fail rather than
silently switching profiles.

### Team and machine principals

cmux team list, cmux team use <id>, and cmux team current manage the selected
team. Every team mutation includes the selected team ID in its request and
response. A missing selection is an error for a team-only action.

A Cloud VM never receives a user's Stack access or refresh token. At create,
the backend may mint a short-lived machine-scoped principal and store only its
hash. A provider edge injects the principal only to the named cmux API origin.
Scopes are deny-by-default:

- read the machine's own status and allowed peers;
- attach, exec, or notify only through an explicit peer grant;
- never create, destroy, snapshot, change billing, or widen a grant.

cmux cloud vm link <source> <destination> --scope attach,exec creates a
directed grant. unlink revokes it. A grant is policy; route files and
enrollment are implementation details.

### Secret rules

- No token or credential in argv, environment snapshots, logs, journal
  records, URLs, package metadata, or VM images.
- Provider, CodeRouter, DNS, and certificate credentials stay in backend
  services or edge rules.
- Agent configuration in a guest contains endpoints and placeholders, not
  bearer secrets. Edge injection supplies short-lived route authority.
- Public URLs are treated as bearer credentials and are redacted from logs.
- File transfer and exec responses have bounded sizes and explicit
  cancellation.

## CLI design

### Grammar and global options

The canonical grammar is:

~~~text
cmux [global-options] cloud <resource> <action> [resource] [options] [-- argv...]
~~~

Aliases are resolved before resource parsing:

~~~text
cmux cloud vm list          # canonical, explicit
cmux vm ls                  # short compatibility alias
~~~

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
cmux cloud capabilities --help
~~~

Help marks each command as headless, desktop, guest, or interactive. An agent
can reject a command that would require a human window.

### Frontend implementation

The Rust CLI is a thin typed frontend over the capability contract. Its
execution pipeline is fixed:

~~~text
argv
→ tokenize without shell evaluation
→ resolve canonical noun and compatibility alias
→ parse a typed action and exact selectors
→ load profile, team, deadline, and output policy
→ preflight capabilities, permission, cost, and confirmation
→ execute through Cloud or remote transport
→ collect operations, events, and verification
→ render one human or machine-readable result
~~~

Each resource module owns its typed command definitions and selector rules.
The top-level dispatcher only resolves aliases and chooses a module. A
CommandContext supplies profile, team, clock, cancellation, transport, and
renderer dependencies. No command reads a singleton, mutates global output
state, or calls the Swift parser.

The schema generates action IDs, option metadata, capability requirements, and
JSON shapes. Human wording and the Ben Swerdlow domain flow remain reviewed
handwritten projections over those generated shapes. This avoids a giant
match statement while also avoiding a generator that invents unsafe UX.

Interactive commands declare their TTY and focus requirements. Headless
commands fail with a typed mode error when they would open a window or take
focus. The same action can expose an interactive projection and a JSON result,
but it cannot silently change side effects between them.

### Output, streams, and exit codes

Human output is concise. Progress and routing decisions go to stderr. Stdout
contains only command data, so a successful cloud run can be piped safely.

json returns one object. jsonl returns one result, event, or operation
transition per line. Every object includes request_id when a request crossed
the API boundary. quiet suppresses successful output but keeps errors.

| Code | Meaning |
| --- | --- |
| 0 | Success or clean stream completion |
| 1 | Cloud operation rejected, remote command failed, or provider failure |
| 2 | Local syntax, selector, profile, or configuration error |
| 3 | Transport, framing, deadline, or protocol failure |
| 4 | Authentication required or refresh failed |

cloud run passes through the remote command exit code. cloud exec returns 1
for a remote nonzero exit and puts the remote exit_code in JSON. This keeps a
shell command's exit namespace separate from cmux's transport namespace.

### Command tree

The target surface is noun-first:

~~~text
auth status|login|logout
team list|current|use
project list|show|dev|env set|env list|env rm|sync

cloud capabilities|describe
cloud operation get|wait|watch|cancel

cloud vm list|get|create|status|stats|wait|wake|sleep|rename|destroy
cloud vm base open|reset
cloud vm snapshot list|create|get|delete
cloud vm fork|restore
cloud vm route|pool list
cloud vm link|unlink
cloud vm ssh|shell|exec|run|push|pull
cloud vm repo clone
cloud vm dev

cloud session list|create|get|attach|detach|resume|close|events
cloud workspace list|create|get|rename|close|delete
cloud workspace layout export|apply
cloud terminal list|get|send|read|wait|resize|signal|close
cloud process list|get|wait|events|cancel

cloud agent list|run|get|wait|logs|stop|resume|fan-out
cloud agent adapter list|describe|install|remove

cloud network status|peers|routes|connect|disconnect
cloud port list|open|close|forward
cloud domains list|zones|verify|publish|access|rm

cloud desktop open|status
cloud browser open|navigate|snapshot|input|close
cloud event stream|read
cloud notification list|read|ack
cloud usage team|machine|agent

coderouter status|session|usage
coderouter account list|add|enable|disable|remove|clear
coderouter agent list|configure

vpn status|up|down|revoke|hosts
~~~

Top-level coderouter and vpn remain because they can serve local and Cloud
clients. cloud network reports the Cloud route used by a command. vpn controls
the local machine's system tunnel. They are not aliases.

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
   ID and base zone, not by a provider domain lookup.
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
   authorization, removes the exact provider rule, and then removes the local
   record. It is safe to retry.

The DNS checklist labels why each record exists. It includes the ownership TXT
record, apex and wildcard routing records, and the _acme-challenge delegation.
When a DNS provider lacks ALIAS, ANAME, or flattening, the output gives the
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
ID, revision and idempotency checks, and complete provider cleanup. A future
breaking CLI version may add an explicit confirmation mode after migration
metrics show that callers can handle it.

### SSH, exec, run, and terminal control

| Verb | Contract |
| --- | --- |
| cloud vm ssh <id> | Interactive shell. Prefer cmux-remote; use OpenSSH only when transport openssh is explicit or the daemon capability is absent. |
| cloud vm exec <id> -- <argv> | One noninteractive direct process, bounded output, structured exit result, no stdin. |
| cloud vm run [--machine <id>] -- <argv> | Route a fresh command by project or work key, optionally sync and pull, then return the remote exit code. |
| cloud terminal send/read/wait | Drive an existing PTY without creating a pane or taking focus. |
| cloud vm push/pull | Resumable, digest-verified transfer with exclusions and size limits. |
| cloud vm repo clone | Clone in the VM so large repositories and credentials do not cross the laptop. |

ssh is an experience and compatibility verb, not the security model. Machine
identity, remote enrollment, and grants decide authority.

## Capability areas

### Machine lifecycle, bases, snapshots, and forks

The base machine is one pinned persistent machine for ongoing work. Pool
machines are router-owned and may be drafted by cloud vm run or cloud agent.
A user-created machine is never drafted because its label says agent-pool;
membership uses a durable server or local binding ID.

Create is asynchronous when a provider may sleep, resume, or provision. It
accepts a caller idempotency key and returns an operation. wait --wake proves
that the daemon and requested image are ready, not only that a provider object
exists.

Snapshots are immutable checkpoints. A fork records the source snapshot and a
new machine ID. Restore checks image and daemon capabilities, freezes
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

1. System VPN: cmux vpn up installs routes for Safari, OpenSSH, curl, and
   other operating-system traffic. It may require root or NetworkExtension.
2. Userspace link: cloud session attach can use cmux-wg without root or a VPN
   prompt. It carries only cmux's authenticated link. The Mac hub shares one
   app tunnel across sidecars; iOS holds one in-process tunnel.
3. Public publication: a port is exposed through the provider TLS edge with a
   generated or verified custom hostname and an explicit access policy.

Public custom-domain publication is currently a Freestyle capability. The
Rust client asks the machine capability catalog before starting it. An E2B or
future provider without the TLS publication contract returns a typed
capability-unavailable result; it must not silently switch providers or expose
a provider URL as if it were a cmux domain.

cloud vm port open returns a private, tokened endpoint and records protocol,
bind, owner, and capability state. It does not create an arbitrary public
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

The backend owns DNS challenges, TLS certificates, provider rules, and private
keys. A publication has exactly one access mode: personal, team, or public.
Changing the mode is an ordered state transition, and deleting a VM first
disables and sweeps every dependent publication.

Machine-to-machine application routes use directed peer grants and named
private services. They are not inferred from shared team membership.

### Agents and CodeRouter

Compute and model credentials are separate resources:

- the machine and workspace provide compute and durable process ownership;
- CodeRouter supplies a model route and usage attribution;
- an agent adapter translates a native CLI into cmux lifecycle events.

Cloud create provisions the guest model-plane configuration. The route token
is injected by the edge for the CodeRouter origin and never written into the
image or environment file. A VM-bound token can read its own usage but cannot
manage team accounts.

Rust CodeRouter commands manage:

~~~text
coderouter status
coderouter session open|close|status
coderouter usage team|machine|agent
coderouter account list|add|enable|disable|remove|clear
coderouter agent list|configure
~~~

Credential intake is from a platform keyring, an explicitly named environment
variable, hidden terminal input, or stdin. Credentials never arrive in argv.
Account selectors are IDs, exact labels, or masked identifiers, with ambiguity
rejected.

Agent adapters are declarative manifests. Each declares stable agent ID and
binary detection, launch/resume/stop/session-ID extraction, hook installation,
native-event mapping, required capabilities and permissions, and safe
transcript sources. Claude, Codex, OpenCode, and Pi are first-party adapter
fixtures, not hardcoded branches in the Cloud transport.

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

### Desktop, browser, notifications, and mobile

Desktop machines expose a VNC/noVNC display as a resource outside a terminal
workspace. Browser surfaces and forwarded ports use the same surface.project
operation as terminals. The CLI can inspect and control them headlessly when
the provider advertises computer-use capabilities.

Notifications are durable machine events. An agent can emit cmux notify inside
a VM without a Mac attached. A reconnecting client drains by cursor and
acknowledges after rendering. Later, the control plane may fan out the same
ledger to iOS push; push is a delivery adapter, not a second event source.

Mobile and desktop clients use the same Cloud resource IDs and capability
responses. The iOS FFI client is a data-plane client; VM lifecycle and billing
remain in the Rust Cloud client and backend.

### Usage, billing, and policy

Every billable or quota-relevant action returns a usage reference and request
ID. The usage ledger records resource IDs, provider, image, agent, model
category, status, and token or machine-time counts. It never records prompts,
outputs, raw commands, credentials, or terminal bytes.

Plan limits, free windows, machine counts, provider budgets, and team
membership are server decisions. The CLI may display a preflight estimate, but
it cannot enforce policy by deleting a machine or guessing a plan.

## Agent-accretive extension contract

### Capability catalog

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
  "preconditions": ["machine.exec.v1"],
  "permissions": ["machine.exec"],
  "effects": ["process.created", "usage.recorded"],
  "observes": ["operation.progress", "process.exit"],
  "verification": ["process.exit.code"],
  "limits": {"output_bytes": 4194304, "deadline_seconds": 30}
}
~~~

An agent can list, filter, and explain actions before invoking them. A human
can inspect and approve the same descriptor in the sidebar or command palette.
Third-party additions are valid only when they use this schema and declare
their permissions.

### Project and adapter manifests

.cmux/cloud.json is a project-owned recipe, not an executable hook. It may
name commands and secret references, but cannot contain a token, arbitrary
provider API call, or local surface ID. Agent manifests follow the same rule.

Initial extension points:

- agent adapters;
- project environment recipes;
- portable layouts;
- browser and verification actions;
- notification and event consumers;
- link handlers and runbooks.

The core does not accept arbitrary plugin code in the remote daemon. A trusted
adapter may request a declared action; the server still checks principal,
capability, revision, and resource ownership.

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
| Desktop app | existing bundled Rust binary and Swift projection | one binary version for local, Cloud, and remote commands |
| VM image | pinned Linux binary, daemon supervisor, common tools, adapters | readiness and capability report before attach |
| SDK/FFI | generated models and narrow data-plane bindings | version negotiation and no hidden singleton state |

Cloud code is measured from a release build after the client lands. The
desktop app must not carry a second copy of the binary. npm and PyPI launchers
must reject a binary with a mismatched protocol or capability manifest.
Release artifacts include checksums, provenance, SBOM, and a rollback channel.

The clean-install matrix covers Linux x64 and arm64, macOS arm64 and x64,
Windows x64, no desktop app, no Bun, offline help, login, VM list, create,
attach, exec, reconnect, and logout.

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
→ cloud vm wait --wake
→ cloud vm ssh or exec
→ cloud session attach
→ cloud agent run through CodeRouter
→ cloud domains verify example.com
→ cloud domains publish <vm> 3000 --domain app.example.com --access team
→ verify the published URL and access policy
→ disconnect and resume
→ snapshot
→ cloud vm destroy
~~~

Project manifests, desktop surfaces, machine-to-machine links, and fan-out are
separate capability slices after this path has a reliable receipt and replay
story. Public custom-domain publication is part of the first release, not a
later parity promise. A server may capability-gate a provider or access mode,
but it must expose the typed zone, TLS, publication, health, and cleanup
workflow from the first release.

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
- Provider SDKs in Rust clients leak provider semantics and credentials;
  backend adapters are the single provider boundary.
- SSH as the only transport loses structured replay, process catalogs,
  capability negotiation, and userspace mobile links.
- One VM per agent task wastes warm state. Use many workspaces in one machine,
  then fork for isolation.
- Polling as the event model burns resources and loses durable ordering. Use
  cursors, bounded replay, and explicit gaps.
- Public port equals public URL. A private port preview and a verified TLS
  publication have different access and cleanup rules.
- Credentials in the image create account-wide compromise from one guest. Use
  scoped edge injection and short-lived machine principals.
- A marketplace before a capability schema produces scripts, not composable
  agent actions.

The main residual risk is contract breadth. The implementation plan keeps the
first release narrow while freezing resource, error, capability, and receipt
shapes early enough for later clients to accumulate value.

## Acceptance and evidence

The design is complete only when these behavior-level checks pass:

1. clean npm and PyPI installs run offline help without the desktop app;
2. one authenticated profile cannot read or mutate another team's machine;
3. retried create, restore, publish, and destroy do not duplicate effects;
4. a sleeping machine reports progress and reaches verified daemon readiness;
5. exec, interactive ssh, and existing-terminal control have distinct output
   and exit contracts;
6. a dropped link resumes from a cursor or returns a typed replay gap followed
   by a snapshot, without spawning a replacement shell;
7. CodeRouter requests from Claude, Codex, OpenCode, and Pi are attributed to
   the correct machine and team without a guest-held route token;
8. a verified custom domain can publish a selected machine port, report TLS
   and health state, enforce personal, team, or public access, and be removed
   without leaving a route;
9. private internal access, userspace links, and public TLS domains cannot
   cross their declared policy boundaries;
10. a closed laptop can receive a durable event and a later client can drain and
   acknowledge it;
11. the final JSON receipt explains what happened without exposing secrets.
