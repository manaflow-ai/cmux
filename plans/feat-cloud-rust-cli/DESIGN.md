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
→ cloud vm wait --wake
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

The clean-install test uses a generated cmux.sh hostname. A separate live
domain smoke must run the customer-zone DNS checklist, repeat verify after the
DNS change, wait for wildcard certificate readiness, exercise protected and
public access, and unpublish. This makes custom-domain support a release
requirement without making package tests depend on a user's DNS provider.

## Fixed architectural decisions

1. cloud resource action is the canonical public grammar. vm and cloud vm
   aliases preserve existing scripts.
2. Rust owns wire models, authentication, team context, Cloud API behavior,
   errors, retries, operations, and command semantics.
3. Swift calls the same Rust contract during migration. It does not retain a
   second Cloud implementation.
4. Backend services own provider SDKs, DNS, TLS, billing, policy, and secret
   custody.
5. cmux-remote owns live terminal, workspace, process, and event transport.
6. Every mutation has an idempotency key and every long mutation has an
   operation receipt.
7. JSON and JSONL are first-class output contracts. Human output is a
   projection of the same result.
8. Team and profile selection are explicit. A command never changes context
   because a previous response happened to mention another team.
9. System VPN, userspace WireGuard, private port access, and public domains
   are separate capabilities.
10. Guest images never contain user, provider, DNS, or CodeRouter bearer
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

## Ownership and dependency graph

| Workstream | Primary paths | Depends on |
| --- | --- | --- |
| Contract | cmux-tui/crates/cmux-cloud-protocol, schema fixtures | none |
| API client | cmux-tui/crates/cmux-cloud-client | Contract, auth |
| CLI frontend | cmux-tui/src/cli/cloud and command dispatch | Contract, client |
| Remote data plane | cmux-remote, cmux-terminal-client | Contract, enrollment |
| Private network | cmux-wg and Swift NetworkExtension bridge | Auth, grants, route API |
| Backend facade | web/app/api, web/services/vms, CodeRouter services | Contract fixtures |
| Guest runtime | image manifest, daemon supervisor, adapters | Capabilities, machine principal |
| Desktop bridge | Sources/Cloud and Swift CLI compatibility files | Rust client, generated models |
| Distribution | cmux-tui/dist, package_npm.py, PyPI workflow, app bundle | Protocol manifest |
| Verification | Rust tests, web tests, hosted E2E, clean-install jobs | Each slice |

The implementation order is:

~~~text
C0 schema and errors
→ C1 auth, profiles, teams
→ C2 HTTP client and capability negotiation
→ C3 machine catalog and operations
→ C4 create, base, snapshot, fork, restore
→ C5 remote sessions, terminal, exec, transfer
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
| base, snapshot, fork, restore | vm base, snapshot, fork, restore routes | generation and capability fences, dependent-resource receipt |
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

Create cmux-cloud-protocol as a pure crate. It must contain:

- generated request and response models;
- stable resource IDs and revisions;
- capability descriptors and protocol versions;
- operation states and receipts;
- normalized error codes and retry classes;
- selectors, pagination cursors, event cursors, and verification receipts;
- redaction and secret-bearing field annotations.

Add checked-in JSON fixtures for auth, team, machine, workspace, terminal,
process, agent run, snapshot, network, port, domain, operation, event,
notification, and every error family. Generate Rust and TypeScript models from
one schema source. Add a conformance test that rejects undocumented fields,
missing required fields, incompatible enum changes, and unredacted secrets.

Define the CLI frontend around a typed CommandContext and resource modules.
The dispatcher resolves aliases and selects a module; it does not contain
provider or resource behavior. CommandContext injects profile, team, clock,
cancellation, transport, and renderer. Generated action metadata supplies
capability and option information, while reviewed handwritten projections keep
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
- Error codes map transport, auth, rate limit, conflict, capability,
  provider, and indeterminate-effect failures.

## C1. Auth, profiles, and team context

Implement an injected AuthStore and platform stores:

- macOS Keychain;
- Linux Secret Service or explicit encrypted mode-0600 fallback;
- Windows Credential Manager or explicit restricted fallback;
- memory-only stdin mode for CI and one-shot jobs.

Implement device/browser login through the existing CLI auth routes, refresh
rotation, logout, expiry reporting, reuse detection, and cancellation.
Persist profile name, account ID, team ID, API origin, and device identity.
Never persist provider secrets in a profile.

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

## C2. API transport and capability negotiation

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
- capability discovery and describe.

Do not add generic automatic retries for mutations. Retry only when the server
declares the effect unobserved or the same idempotency key makes the request
safe. Preserve the original deadline across auth refresh and provider phases.

Commands:

~~~text
cmux cloud capabilities [--json]
cmux cloud describe <resource-or-action> [--json]
~~~

Expert review question: can a timeout create two machines or two publications?
If the answer depends on a caller remembering a flag, the client is unsafe.
Idempotency and reconciliation belong in the client and server contract.

Acceptance:

- Fixture tests cover every retry class and deadline phase.
- Capability mismatch returns a stable error with an available fallback.
- Logs contain request and trace IDs but no tokens, terminal bytes, or URLs
  that carry credentials.

## C3. Machine catalog and operations

Implement:

~~~text
cmux cloud vm list|get|status|stats|wait|wake|sleep|rename|destroy
cmux cloud operation get|wait|watch|cancel
~~~

Support filters for team, project, state, image, pool, capability, and
freshness. A display name is never an identity. Ambiguous names return all
candidate IDs. Include image, daemon, route, billing, and capability state in
machine detail.

Machine creation, wake, sleep, restore, publication, and destroy return
operations when provider work can outlive a request. Implement progress,
poll-after hints, cancellation tombstones, stale-create reconciliation, and
late-callback protection. A wait command proves daemon readiness and requested
capabilities, not only provider existence.

Expert review question: can a killed client recover the truth about a create?
If not, operation lookup by idempotency key and reconciliation are incomplete.

Acceptance:

- Repeated list and wait calls are bounded and cancellable.
- A canceled or stale create leaves no unowned provider resource.
- Sleep and wake preserve stable machine ID and report capability changes.
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

Use capability checks before a provider call. Restore and delete are
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
Machine-to-machine routes require directed grants, not team membership alone.

Public custom-domain publication is currently a Freestyle capability. The
Rust client must preflight that capability and return a typed
capability-unavailable result for E2B or another provider without the TLS
publication contract. It must not silently expose a provider URL or switch
providers.

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
backend still requires exact ownership and completes provider cleanup before
reporting success.

The Rust implementation must retain the flow from
[the public-domain design](../feat-cloud-vm-public-urls/DESIGN.md): provider
TLS and DNS operations remain backend-owned, protected viewers use the
sign-in or denial page with no request-access action, and unpublish or VM
deletion removes authorization and the exact provider rule before local
cleanup. Do not replace this with a singular domain namespace, an ID-only
workflow, or a generic port-open command.

Expert review question: can a public URL accidentally expose a private service,
or can a local VPN command alter Cloud policy? If yes, boundaries are mixed.
Provider networking, DNS, certificates, and private keys remain backend-owned.

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
defaults. It cannot contain secret values, provider calls, local surface IDs,
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

Separate compute ownership from model routing. The machine owns the process
and workspace. CodeRouter owns upstream account selection, model route,
affinity, cooldown/failover, and usage attribution. A short-lived VM-bound
route token is edge-injected and is never written to the image or guest
credential file.

Adapter manifests declare binary detection, launch/resume/stop, session-ID
extraction, hook installation, event mapping, required capabilities,
permissions, and safe transcript sources. Claude, Codex, OpenCode, and Pi are
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

Desktop Swift uses the same resource IDs, capability catalog, and receipts.
The iOS FFI surface stays narrow and data-plane focused. Lifecycle, billing,
and policy remain in Rust Cloud client and backend.

Expert review question: can two clients disagree about whether an agent needs
attention? If yes, event ordering, cursor ownership, or projection rules are
not explicit.

Acceptance:

- A disconnected client drains retained notifications in order.
- Cursor expiry returns a gap plus snapshot/describe recovery.
- Desktop and mobile show the same machine and session identity.
- Browser and VNC actions are gated by advertised computer-use capabilities.

## C10. Swift migration and removal

During one compatibility window:

1. Swift command names call the Rust client through a narrow bridge.
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
capability manifest. The desktop app reuses its existing bundled Rust client;
measure the release-build delta after Cloud code lands rather than guessing
from debug artifacts.

The clean-install matrix covers:

- macOS arm64 and x64;
- Linux arm64 and x64;
- Windows x64;
- no desktop app, no Bun, and offline help;
- login, team selection, VM list/create/wait, attach, exec, reconnect, and
  logout.

Publish provenance, SBOM, checksums, and a rollback channel. Verify that a
package cannot silently download an incompatible guest daemon. Keep the VM
image's cmux binary and capability manifest pinned.

Expert review question: would a release maintainer detect an architecture or
protocol mismatch before a user loses work? If not, package validation is too
weak. A size estimate without a release build is not evidence.

Acceptance:

- Clean npm and PyPI installs pass the complete path.
- Desktop bundle contains one matching Rust client.
- Windows and Linux commands have equivalent JSON and exit behavior.
- Version and capability mismatch fails with an actionable error.

## Cross-cutting test matrix

Every slice adds behavior tests in the narrowest suitable layer:

| Concern | Required proof |
| --- | --- |
| Auth and scope | profile isolation, team permissions, refresh rotation, redaction |
| Idempotency | retried create, restore, publish, destroy, and cancellation |
| Concurrency | revision conflicts, duplicate names, late provider callbacks |
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
2. C6 private attach and public custom-domain publication complete. A provider
   or access mode may be capability-gated, but the typed zone, TLS,
   publication, health, and cleanup workflow must be shipped.
3. C8 supports the first selected agents with CodeRouter receipts.
4. Swift compatibility produces no divergent Cloud state.
5. Hosted E2E and clean npm/PyPI checks have run once.
6. Security review accepts token, grant, publication, and transfer boundaries.
7. Documentation links, generated schemas, and migration metrics are current.

Do not promise arbitrary third-party plugins, unrestricted fan-out, provider
commands, or process continuity across restore before their capability and
policy tests exist. These are explicit exclusions, not hidden TODOs.

## Open decisions requiring product input

- Which agents are required for the first external Cloud release?
- Should vm remain a documented alias indefinitely, or expire after migration?
- Which OS keyring fallback modes are allowed in CI and managed environments?
- Which desktop-only actions must have a headless equivalent before Swift Cloud
  commands are removed?
- What cost and concurrency limits apply to fan-out and long-running agents?
