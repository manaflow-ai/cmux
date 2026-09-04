# Cloud guest command policy

Status: normative target for the Rust CLI and the cmux daemon in a Cloud VM.

This document defines every public cmux command that a process in a Cloud VM
can call. A command not listed here is denied in guest context.

## Security claim

Treat every guest process as hostile. Also test with full VM root access. Root
can replace the guest CLI, daemon, and firewall. The hard Mac, peer, account,
and model boundaries must therefore run outside the VM.

A guest can control its leased VM resource graph and exact granted peer
services. VM root can control all state in its one project trust domain. No
guest authority can:

- start a connection to the Mac;
- name or read a Mac resource;
- use the Mac as a file, browser, device, process, or network proxy;
- reach a peer outside a declared service route or exact grant;
- call Cloud account, billing, machine-lifecycle, domain, or network policy;
- export a reusable peer, model, or Cloud credential.

The Mac can start an authenticated session to a VM. The network admits only
return traffic for that established flow. This does not make the Mac a VPC
peer.

The guarantee covers cmux-managed routes and known device identities. If a user
independently makes a Mac service public through an unrelated Internet address,
cmux cannot prove that an arbitrary public site is not that service. The default
guest policy therefore has no public Internet access. Enabling `internet`
accepts this residual risk. The managed egress layer still blocks known Mac
addresses, device domains, gateways, private ranges, and routes.

## Trust and ownership model

One VM is one project trust domain. Workspaces in that VM share its Unix user,
files, process table, and caches. A workspace lease limits cmux API actions. It
does not make two same-VM processes confidential from each other. Mutually
untrusted work uses a separate warm VM or snapshot fork.

Every guest request is bound to:

- one machine identity;
- one daemon session;
- one lease;
- an explicit set of VM workspace IDs;
- one project-root file grant;
- exact effect and resource limits;
- exact peer-service or peer-action grants;
- a generation, nonce, and expiry.

The default lease contains one workspace. A workspace that the same lease
creates joins the lease. Existing workspaces need an explicit host or
orchestrator grant. `current` always means current inside this VM lease. It can
never mean the focused Mac resource.

## Execution contexts

The same Rust implementation has three authenticated contexts:

| Context | Authority | Visible state |
| --- | --- | --- |
| `guest` | VM-local daemon plus signed lease | Leased VM graph and granted peer services |
| `host-cloud` | Cloud API plus remote session | Account Cloud objects and host-selected projections |
| `host-local` | Local cmux socket | Local Mac resources |

The daemon handshake selects guest context. An environment variable or CLI
flag cannot select it. A guest rejects `--socket`, host placement flags, a host
socket environment, and every fallback transport. A missing guest daemon fails
with `transport.unavailable`. It never tries a local socket.

The parser hides host-only commands from guest help. The daemon authorizer
checks the action again. The parser is an ergonomics layer, not the security
boundary.

## Action contract

Each atomic action has a complete, non-empty effect set. A composite command
declares its ordered atomic plan and the union of all effects before work starts.

| Effect | Direct authority |
| --- | --- |
| `query` | Read bounded state inside the lease |
| `topology` | Change the VM workspace graph |
| `process` | Start or control a VM process |
| `terminal-io` | Read or write a leased VM terminal |
| `viewer` | Create or control a VM-owned viewer |
| `network` | Use an allowed VM or peer destination |
| `computer-use` | Send typed input to a VM browser or desktop |
| `transfer` | Move bounded data between granted VM paths |
| `peer-network` | Use a named peer service or exact peer action grant |
| `event` | Read or emit a bounded VM event |
| `model` | Read current VM model-route state or use its local endpoint |

Effect metadata is not an operating-system sandbox. `process`, terminal input,
browser input, and VM desktop input can do anything that the VM Unix user can
do. The VM trust domain, managed network, and host boundary contain those
indirect effects.

Each command also has one primary result shape:

| Shape | Agent behavior |
| --- | --- |
| `result` | Read one bounded object and finish |
| `receipt` | Keep stable IDs, revision, and idempotency receipt |
| `operation` | Keep the operation ID, watch or wait, and cancel explicitly |
| `stream` | Read JSONL, keep the cursor, and handle an explicit gap |
| `interactive` | Hold the input lease, detach, and keep the resume cursor |
| `transfer` | Track direction, digest, byte limit, progress, and final receipt |

No guest command creates a Cloud `operation`. Cloud machine creation and other
host control-plane work can use that shape.

The compiled action registry drives the parser, daemon authorization,
`--help --json`, projection filtering, and behavior fixtures. It is local
metadata. It is not a user-facing capabilities catalog. A registry entry uses
this shape:

```json
{
  "action_id": "browser.open",
  "contexts": ["guest"],
  "effects": ["viewer", "topology", "network"],
  "selector_scope": "lease.vm.browser",
  "input": "vm_url",
  "host_authority": false,
  "projection_event": "resource.created",
  "retry": "safe_read",
  "limits": {"result_bytes": 1048576}
}
```

`projection_event` means that a host-selected subscription can mirror a VM
state change. It does not let the guest select a Mac workspace, pane, surface,
window, focus target, or presentation policy.

One registry prevents drift, but it is not the only security decision. The
daemon independently rejects every guest action with a host selector, host
effect, or Cloud control-plane prefix. The host projection accepts only its
small structural event schema and never trusts action metadata sent by the VM.
The managed network evaluates machine identity and grants without consulting
the guest registry. Hand-written deny tests cover these independent rules. A
bad registry entry must therefore fail closed at another boundary.

A host attaches one remote workspace to one projection container. The
container can be a dedicated Cloud workspace or a bounded pane subtree. The
reconciler accepts only descendants of that remote workspace and maps their
VM topology inside the container. A guest can create, move, reorder, focus,
and detach tabs, panes, and surfaces there. It cannot cross the container
boundary. A guest-created workspace appears in the host Cloud tree but stays
closed until the host attaches it. The host can move or close the complete
container without changing VM topology.

The projection mirrors layout by default and does not follow guest focus. A
host user can enable follow-focus for one container. Even then, guest focus can
select only a descendant inside that container and cannot move Mac keyboard
focus, activate another window, or take global input.

Host keyboard and pointer input uses an input lease bound to one projection
ID, remote surface ID, and input epoch. Guest focus never retargets that lease.
Closing or replacing the remote surface revokes it, and later input is dropped.
A move can preserve input only when the same remote surface and projection
binding survive. Pointer input also names the exact VM frame sequence that
supplied its coordinates.

Text that a user types into a selected projection is an intentional transfer to
the VM and is visible to VM root. Host-owned identity chrome, disabled autofill,
disabled password managers, and the input lease reduce accidental disclosure.
They cannot make text safe after the user sends it to a hostile VM.

## Complete guest command allowlist

### Context and discovery

```text
cmux context [show] [--json]
cmux tree [--json]
cmux machine self show|status|stats [--json]
cmux server status [--json]
cmux session current show|snapshot|ping [--json]
cmux session current events [--jsonl]
cmux session current journal read [--from tail|beginning] [--jsonl]
cmux --help
cmux <allowed-scope> --help --json
```

`context` returns the guest IDs, project grant, expiry, limits, and granted
peer services. `tree` returns only the lease closure. Neither command returns a
host ID, host path, account token, global machine catalog, or local route.

### VM workspace graph

```text
cmux workspace list
cmux workspace create [--name <name>]
cmux workspace <workspace> show|rename|move|reorder|focus|close
cmux workspace <workspace> run -- <argv...>
cmux workspace <workspace> layout export|apply

cmux screen list
cmux screen create [--name <name>]
cmux screen <screen> show|rename|focus|close
cmux screen <screen> layout export|apply|undo

cmux pane list
cmux pane create
cmux pane <pane> show|rename|focus|close|split|neighbor|swap|zoom
cmux pane <pane> run -- <argv...>
cmux pane <pane> focus direction <left|right|up|down>
cmux pane <pane> split ratio set <ratio>
cmux pane <pane> viewport width set <columns>

cmux tab list
cmux tab create terminal
cmux tab create browser --url <vm-url>
cmux tab <tab> show|rename|move|reorder|focus|close

cmux surface list
cmux surface <surface> show|open|rename|move|reorder|focus|attach|detach
```

All selectors resolve inside the same machine and lease. `focus` is VM logical
state. It cannot focus a Mac window or take Mac input. A cross-workspace move or
swap works only when both workspaces are in the lease.

Workspace, screen, pane, and tab `close` detach topology. They keep the
underlying terminal, browser, viewer, or desktop resource alive. The generic
`surface close` form is denied because it hides the resource lifecycle.
`terminal close`, `browser close`, or `viewer close` ends the named resource.

### VM terminals and processes

```text
cmux terminal list
cmux terminal <terminal> show|write|keys|mouse
cmux terminal <terminal> focus <in|out>
cmux terminal <terminal> screen read|wait
cmux terminal <terminal> state read
cmux terminal <terminal> history read
cmux terminal <terminal> output read
cmux terminal <terminal> process show|wait
cmux terminal <terminal> viewport scroll
cmux terminal <terminal> resize|signal|move|attach|close

cmux process list
cmux process <process> show|wait|events|cancel
cmux run -- <argv...>
cmux exec -- <argv...>
```

`exec` runs exact argv without a PTY, waits to an absolute deadline, and returns
bounded stdout, stderr, and exit state. `run` creates a durable process and
terminal, then returns their IDs immediately. Use `run` for long or interactive
work. Workspace and pane `run` are placement forms of the same action.

The lease can control only its own or explicitly adopted processes and
terminals. No command accepts a host file descriptor, shell state, clipboard,
SSH agent, or local input event. `terminal copy`, `terminal history clear`, and
`terminal project` are denied.

### VM files, diff, Markdown, media, and desktop

```text
cmux open <vm-relative-path>
cmux viewer list
cmux viewer <viewer> show|reload|close
cmux viewer <viewer> media play|pause
cmux viewer <viewer> media seek <time>
cmux diff --repo <vm-relative-repo> [--format structured-v1]
cmux markdown open <vm-relative-path>

cmux desktop list
cmux desktop <desktop> show|snapshot|accessibility
cmux desktop <desktop> key|text
cmux desktop <desktop> mouse|wheel --pointer-frame-seq <sequence>
cmux desktop <desktop> attach|detach
```

Every path is rooted in the VM project grant. The daemon canonicalizes the
path, rejects traversal and unsafe symlinks, limits bytes and decode cost, and
returns a digest. Diff and Markdown viewers are read-only. An edit uses a
separate VM process action.

`open`, `diff`, `markdown open`, and `browser open` use the same placement
rules as local cmux, but they mutate the calling VM workspace. The caller
workspace and surface IDs are untrusted hints checked against the lease. The
command returns the new or reused VM resource ID even when no host is attached.
If the workspace has a projection, the revisioned topology event makes the
viewer appear inside that container. It never asks the Mac to open the path or
URL.

Markdown is inert. Scripts, active HTML, remote subresources, and custom
schemes are disabled. Image, video, and archive preview uses a bounded VM
decoder or VM-rendered frames. File, diff, Markdown, image, and video resources
share the `viewer` lifecycle. A guest-started video projection is muted. Only a
local user can enable host audio. Media commands cannot control a Mac media app
or system volume.

Desktop commands address only the VM display. Accessibility output is a
bounded VM tree. Pointer input must name the frame sequence that supplied its
coordinates. Stale input fails. `desktop detach` closes the view stream, not
the VM desktop service. Desktop service lifecycle is host-only.

### VM browser

```text
cmux browser list
cmux browser open <vm-url>
cmux browser <browser> show
cmux browser <browser> navigate <vm-url>
cmux browser <browser> back|forward|reload|activate
cmux browser <browser> snapshot [--interactive]
cmux browser <browser> screenshot
cmux browser <browser> wait <condition>
cmux browser <browser> click|dblclick|hover|focus|check|uncheck <target>
cmux browser <browser> fill|type <target> <text>
cmux browser <browser> press <key>
cmux browser <browser> select <target> <value>
cmux browser <browser> is <visible|enabled|checked> <target>
cmux browser <browser> scroll-into-view <target>
cmux browser <browser> scroll [<target>] --dx <n> --dy <n>
cmux browser <browser> get <url|title|text|html|value|attr|count|box|styles> [<target>]
cmux browser <browser> find <role|text|label|placeholder|alt|title|testid> <value>
cmux browser <browser> frame <main|parent|selector>
cmux browser <browser> dialog <accept|dismiss> [<text>]
cmux browser <browser> console|errors
cmux browser <browser> eval <javascript>
cmux browser <browser> viewport <width> <height>|reset
cmux browser <browser> key|text
cmux browser <browser> mouse|wheel --pointer-frame-seq <sequence>
cmux browser <browser> attach|close
cmux browser <browser> download list
cmux browser <browser> download save <vm-relative-path>
```

The browser engine, DOM, JavaScript, cookies, storage, downloads, profile, and
network stack all run in the VM. The Mac receives pixels and sends explicit
input on a host-started projection. It never loads the VM URL in a Mac WebView.

`snapshot` returns stable element references for one document and frame
revision. `click`, `fill`, `press`, `select`, `is`, `wait`, `get`, and `find`
are the normal agent path. They use fewer tokens and fail more clearly than
pixel coordinates or JavaScript. References expire after a document or frame
change. Pointer input and `eval` are VM-only fallbacks.

The default browser profile is `project`. It permits:

- `file:` within the VM project grant;
- VM loopback and assigned VM interfaces;
- declared same-project `project-app` services;
- exact `peer://<peer-id>/<service>/...` grants.

A host can select `machine-only` to remove peer access. Public destinations
need an expiring, lease-scoped `internet` grant, optionally limited to exact
domain suffixes. Team policy can forbid or narrow that grant. A guest cannot
change the profile or grant. Every profile blocks known Mac identities and
domains, the Mac gateway and LAN, metadata, link-local, unapproved private
ranges, and daemon control ports. The managed network repeats this decision
for DNS results, redirects, subresources, WebSockets, WebRTC, downloads, and
IPv4, IPv6, mapped, or integer address forms.

A denied public navigation returns `network.egress_denied`, the requested
origin, and one copyable host command. For example:

```text
cmux cloud network egress <session> set internet --ttl 1h --domain example.com
```

The guest cannot run or approve that command. After the host changes the lease,
the guest retries the original browser action. There is no hidden approval or
automatic widening.

The first release omits profile import, host cookie import, browser-state
import, network interception, geolocation, offline emulation, tracing,
extension management, and browser debug endpoints. This keeps the public
action surface small. It is not an isolation claim against VM root, which
already owns the VM browser profile.

### Peer VMs

```text
cmux peer list
cmux peer <peer> show
cmux peer <peer> resolve <service>
cmux peer <peer> forward <service> [--local-port <port>]
cmux peer forward list
cmux peer forward <forward> show|close
cmux peer <peer> shell
cmux peer <peer> exec -- <argv...>
cmux peer <peer> push <vm-relative-source> <vm-relative-destination>
cmux peer <peer> pull <vm-relative-source> <vm-relative-destination>
```

`peer list` returns only peers and services available to this lease. It does
not return the account machine catalog. A `peer://` endpoint resolves machine
identity plus a declared service, not a guest-supplied raw IP.

Same-project machines get `project-app` access to application ports declared
in `.cmux/cloud.json`. The declaration contains a stable service name, protocol,
port, and peer policy. It never includes a daemon control port. `machine-only`
removes the default route.

Peer shell, exec, push, pull, raw ports, UDP, and cross-project access need an
exact host or orchestrator grant. The host grammar is:

```text
cmux cloud network grant create <source> <destination> \
  --service web --allow connect --ttl 1h
cmux cloud network grant create <source> <destination> \
  --allow shell|exec|push|pull --ttl 1h
cmux cloud network grant create <source> <destination> \
  --endpoint tcp:3000 --allow connect --ttl 1h
```

Wildcards and port ranges are invalid. Transfer grants also carry exact source
and destination path roots, byte limits, digests, deadlines, and direction.

Peer actions use a VM-local broker. The managed fabric combines the signed
grant with source machine identity outside guest control. No reusable
destination bearer enters the guest. Copying a grant request or broker state to
another VM does not authorize it. `peer forward` binds only to source-VM
loopback. No peer action accepts a Mac address, host path, local descriptor,
SSH-agent forward, public listener, wildcard bind, or destination daemon socket.

### Agent, event, notification, and model status

```text
cmux agent list
cmux agent report --terminal <terminal> --state <state>
cmux agent hook status
cmux agent hook emit --event <native-event> [--terminal <terminal>]
cmux event stream|read
cmux notification list
cmux notification create --title <text> --body <text>
cmux notification <notification> read|ack
cmux notify --title <text> --body <text>

cmux coderouter status
cmux coderouter session current show|status
cmux coderouter model list
cmux coderouter usage self
```

The image installs signed agent adapters. A guest can read status and emit
events, but it cannot install, replace, or remove an adapter. VM root can forge
events in its machine. Treat these as untrusted status. They cannot authorize
billing, grants, account changes, host actions, peer actions, or a command in a
result.

Notifications are inert text plus an optional typed VM resource. A host-selected
subscription can show them with size and rate limits. They cannot contain an
active URL, local path, shell command, custom scheme, or authority request.

The guest receives a VM-local model endpoint, not a reusable bearer. A managed
edge verifies source machine identity outside the VM and adds short-lived model
authority. VM root can spend the machine model allowance. It cannot export a
credential that works from another machine or call Cloud administration.
Account login, account mutation, team usage, token export, and route-policy
changes are host-only.

## Complete effect assignment

| Actions | Effects |
| --- | --- |
| context, tree, machine self, server status, session show, snapshot, ping | `query` |
| session events and journal read | `event` |
| workspace, screen, pane, tab, surface list or show | `query` |
| workspace, screen, pane, tab create and topology mutation | `topology` |
| surface open, rename, move, reorder, focus, attach, detach | `topology` |
| workspace run and pane run | `topology`, `process` |
| terminal list, show, screen, state, history, output, process show or wait | `query` |
| terminal write, keys, mouse, focus, viewport, resize, attach | `terminal-io` |
| terminal signal and process cancel | `process` |
| terminal move | `topology` |
| terminal close | `topology`, `process` |
| process list, get, wait | `query` |
| process events | `event` |
| exec | `process` |
| run | `topology`, `process` |
| file, diff, Markdown open | `viewer`, `topology` |
| viewer list or show | `query` |
| viewer reload and media controls | `viewer` |
| viewer close | `viewer`, `topology` |
| desktop list | `query` |
| desktop show, snapshot, accessibility, attach, detach | `viewer` |
| desktop key, text, mouse, wheel | `computer-use` |
| browser list or show | `query` |
| browser open | `viewer`, `topology`, `network` |
| browser navigate, back, forward, reload, dialog, eval | `viewer`, `network` |
| browser activate | `viewer`, `topology` |
| browser snapshot, screenshot, wait, get, find, frame, console, errors, is, viewport | `viewer` |
| browser semantic, select, scroll, key, text, mouse, or wheel input | `viewer`, `computer-use`, `network` |
| browser attach | `viewer` |
| browser close | `viewer`, `topology` |
| browser download list | `query` |
| browser download save | `viewer`, `transfer` |
| peer list, show, resolve | `query` |
| peer forward create or close | `network`, `peer-network` |
| peer shell | `network`, `peer-network`, `topology`, `process` |
| peer exec | `network`, `peer-network`, `process` |
| peer push or pull | `network`, `peer-network`, `transfer` |
| agent list and hook status | `query` |
| agent report, hook emit, event and notification mutation | `event` |
| CodeRouter guest reads | `model` |

## Complete result-shape assignment

| Actions | Shape |
| --- | --- |
| context, tree, machine, server, session, resource, terminal, process, viewer, desktop, browser, peer, notification, and CodeRouter bounded reads | `result` |
| workspace, screen, pane, tab, surface, terminal, viewer, desktop, browser, peer-forward, agent-report, and notification mutation | `receipt` |
| exec, terminal wait, process wait, browser wait, browser eval, and peer exec | `result` |
| run, workspace run, and pane run | `receipt` |
| session events, journal read, process events, event stream or read | `stream` |
| terminal attach, browser attach, and peer shell | `interactive` |
| peer push, peer pull, and browser download save | `transfer` |

A `result` can wait to its absolute deadline, but it cannot leave hidden work
after it returns. A `receipt` identifies durable work that continues. An
interactive result returns its stream ID and detach rule before it accepts
input.

## Host-only command families

The following families are never available to a VM guest:

```text
server start|ensure|stop|reload-config
machine list|show|session
session list|open|shutdown|stop|reset-state|config|window|terminal-defaults

auth login|status|logout
team list|current|use
project list|show|dev|env set|env list|env rm|sync

cloud operation <operation> show|wait|watch|cancel
cloud vm list|create
cloud vm <machine> show|status|stats|wait|wake|sleep|rename|destroy
cloud vm base open|reset
cloud vm <machine> snapshot list|create
cloud snapshot <snapshot> show|delete|fork
cloud vm <machine> restore|route|ssh|shell|exec|run|push|pull|repo clone|dev
cloud vm pool list
cloud session list|create
cloud session <session> show|attach|detach|resume|close|events
cloud workspace|screen|pane|tab|surface <all actions>
cloud terminal|process <all actions>
cloud agent list|run
cloud agent <run> show|wait|logs|stop|resume|fan-out
cloud agent adapter list|describe|install|remove
cloud network status|peers|routes|connect|disconnect
cloud network grant list|create
cloud network grant <grant> show|revoke
cloud network egress <session> show|set
cloud port list|open|close|forward
cloud domains list|zones|verify|publish|access|rm
cloud desktop|browser <all actions>
cloud projection list|attach
cloud projection <projection> move|detach
vpn status|up|down|revoke|hosts

pairing ...
client ...
sidebar ...
remote ...
raw ...
```

`cloud vm list` is the host account catalog. A guest uses `machine self` and
`peer list`. Domain publication keeps the established Ben Swerdlow verbs and
flow, but verification, publication, access policy, and removal are host
control-plane actions.

Also deny host IDs, host paths, host URLs, existing Mac browser state, host
clipboard, keychain, accessibility, camera, microphone, screen, SSH agent,
local process, socket, file descriptor, reverse relay, raw RPC, browser profile
import, agent-adapter installation, and any future action that has no reviewed
guest registry entry.

## Mac boundary and projection

The managed network has no VM-originated route to the Mac. It rejects the Mac
as a source or destination principal, including device aliases, gateways,
subnet advertisements, service advertisements, spoofed sources, reverse
forwards, metadata, and daemon ports. The Mac listener has no public or
VPC-routable bind.

The Mac opens an authenticated outbound projection circuit to the VM or relay.
It has typed streams for VM frames, state receipts, and explicit input. The
guest cannot choose the host endpoint, open a second stream, send arbitrary
protocol bytes, or request a host fetch. Closing the host session removes its
return-flow state.

The projection parser is sandboxed and has no local filesystem, process,
clipboard, keychain, browser-profile, device, or general network authority. It
strips hostile terminal links, clipboard escapes, path actions, command actions,
and unsafe schemes. Malformed or oversized frames close the circuit.

Every projected surface has host-owned chrome that shows machine and project
identity. VM frames cannot cover it. Projection disables host autofill,
password managers, clipboard, drag and drop, automatic audio, and global input
capture. The host sends input only while the user has selected that exact
projected surface. The input lease stays bound to that remote surface ID.
Guest focus remains VM state and cannot select a Mac window.

The projection container owns all local IDs. Its reconciler maps a remote
workspace revision to local presentation state without returning local IDs to
the VM. A remote create, move, reorder, focus, attach, or detach event can
change only that mapping. New remote workspaces, windows, top-level host tabs,
sidebars, menus, notifications with actions, and system UI need a separate
host action and are never created by the reconciler.

A user can explicitly push one selected, bounded file to a generated VM path.
The VM never selects the host path and never receives it. Recursive mounts,
host browser handoff, drag and drop, and implicit paste or download transfer are
not in the first release. A VM artifact reaches the Mac only through a
host-started pull with a selected destination.

## Expert decision record and trade-offs

| Decision | Rejected expert objection | Choice and trade-off |
| --- | --- | --- |
| One Rust command core | A security expert rejects a guest-mode environment switch. | Derive context from the authenticated daemon handshake and enforce it again at the owner. A separate guest binary reduces accidental exposure but duplicates release and protocol work. |
| Workspace scope | An isolation expert rejects calling a same-VM lease a data sandbox. | One VM equals one project trust domain. Separate warm VMs or forks cost compute and make the security claim true. |
| VM peers | A network expert rejects all-to-all private IP access. | Allow declared same-project app services by default. Require exact grants for stronger work. This adds manifest and grant steps and limits lateral movement. |
| Peer authority | A credential expert rejects a portable peer bearer. | Combine a signed grant with source machine identity outside the VM. This adds a broker hop and makes replay and revocation reliable. |
| Mac access | A network expert rejects a full-mesh host VPN. | Let the Mac start exact flows and allow established replies only. Stateful rules add network work and keep host listeners unreachable. |
| Browser | A browser expert rejects loading the VM URL in a host WebView. | Run the complete browser in the VM and project pixels. This uses more VM compute and keeps host cookies, DOM, files, and network out of scope. |
| Browser controls | An agent-tooling expert rejects routine use of pixels or JavaScript. | Use revisioned references and semantic browser actions first. This adds typed verbs and reduces tokens and stale actions. |
| Remote files | A privacy expert rejects a host picker or shared mount callable by a guest. | Accept only VM paths. A user can make one audited host-to-VM copy. This is less convenient and removes a host file oracle. |
| Projection | A desktop expert rejects remote pixels that can impersonate trusted UI. | Use unforgeable host chrome and disable host integrations. This uses screen space and makes the trust boundary visible. |
| Projected input | A privacy expert rejects any claim that selected remote input remains local. | State that typed text enters the VM, bind it to one surface and epoch, and disable password managers and implicit clipboard. This preserves useful interaction but requires user care with secrets. |
| Model authority | A credential expert rejects a bearer in guest memory. | Use a VM-local endpoint plus external machine identity. Root can spend its machine allowance but cannot export it. |
| Discovery | An API expert rejects a large, stale capability catalog. | Use local `--help --json`, `context`, and typed errors. This removes a round trip and keeps action checks specific. |
| Shared registry | A security expert rejects one metadata bug that changes every enforcement layer. | Generate consistent action data, then enforce independent host-selector, projection-schema, and network invariants. This duplicates a small deny core and prevents common-mode authority failure. |

The main implementation risk is drift between parser metadata, daemon
authorization, managed network rules, and host projection. Generate action
metadata from one registry and run the same fixtures at every layer.

## Required security and behavior tests

- Guest help contains only this allowlist. Direct calls to each host action
  fail at the daemon with the same non-enumerating denial.
- A malicious or incorrect registry entry cannot enable a host selector,
  projection message, Cloud control action, or network route.
- The denial still holds after test code gains VM root, replaces the guest CLI
  and daemon, changes the guest firewall, and sends raw packets.
- A Mac-started VM flow gets replies. A new VM-to-Mac connection, datagram,
  reverse forward, spoofed source, or advertised route is denied.
- Encoded IPv4, IPv6, mapped, integer, DNS, redirect, subresource, WebSocket,
  WebRTC, link-local, metadata, private, and known Mac destinations are denied.
- A guest tree contains only its lease. Valid host, peer, and unleased IDs do
  not reveal whether those resources exist.
- The scheduler never puts two project trust domains in one VM.
- Same-project declared services work. Peer daemon ports, undeclared ports,
  cross-project peers, and copied peer grants fail.
- Browser references expire on document revision. Semantic and pointer actions
  cannot escape the VM destination policy.
- Malicious terminal, Markdown, HTML, media, archive, browser, and desktop data
  cannot make the Mac open a path, URL, process, clipboard, device, or network
  request.
- Projected VM content cannot cover host identity, use host autofill or password
  managers, start host audio, capture global input, or receive Mac pixels.
- Guest focus, close, or replacement cannot retarget queued Mac input to a
  different VM surface. The old input lease fails.
- Explicit text reaches only the selected VM surface. Autofill, password
  managers, clipboard, and unselected keyboard input never enter the circuit.
- Forged agent events can change only untrusted status in their own machine.
  They cannot change billing, grants, or host state.
- VM root can use its local model endpoint, but no reusable model credential is
  readable or replayable from another machine or network identity.
- Lease revoke and machine destroy close projections, input leases, peer routes,
  browser streams, viewers, and transfers. Old requests fail.

## Secure 80/20 release slice

Build this path first:

```text
host:  auth -> fast warm VM create -> attach one workspace
guest: context/tree -> run terminal work -> arrange panes/tabs/surfaces
guest: open file/diff/Markdown -> open and automate VM browser
guest: use declared peer service -> use VM-local model endpoint
host:  detach -> reconnect same state -> pull selected artifact -> destroy
```

Public custom-domain publication is also in the release through the established
domain flow. It publishes a VM port at the managed edge. It does not add a Mac
route or let a VM change domain policy.

Defer host browser handoff, recursive host mounts, mixed local and remote layout
control, implicit clipboard transfer, profile import, and raw host socket relay.
These features add host authority and are not needed for the complete remote
agent workflow.
