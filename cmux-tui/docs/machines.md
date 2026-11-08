# Machines

The optional machine rail adds a connection layer to the native column stack. Selecting a machine replaces the attached cmux session while the client, rail layout, mouse handling, and workspace rendering stay local.

The feature is disabled by default. It activates when `machine_sidebar.enabled` is `true`, `machine_sidebar.create_sources` is nonempty, or the `machines` array contains at least one valid entry. An active static catalog always starts with the current local session, labeled with the local hostname and `local`, followed by configured Unix-socket and SSH targets. A configured machine with id `current` is skipped because that id belongs to the local entry.

There is no master or slave role. The rail follows capabilities available to this client. A laptop can expose SSH and VM targets, while a headless Linux session can expose Docker devboxes through the same source contract. A client with no machine targets, creation sources, or enabled machine sidebar keeps the rail hidden. Host location does not change the model.

## Layout and input

`sidebar.views` controls the order, resource path, width, and collapse priority of native rails. One-level machine, workspace, pane, tab, and agent views render as lists. Multi-level paths render collapsible trees, including workspace/agent and workspace/pane/tab representations. Every divider remains independently draggable, and all views preserve at least 40 pane columns.

`Ctrl-b S` prefers the first view containing workspaces. Left or `h` and Right or `l` traverse adjacent configured views. In a tree, Left collapses an expanded branch and Right expands a collapsed branch before changing columns. Up/Down or `k`/`j` changes the current selection. Enter activates it, Space toggles a branch, and Esc returns to the active pane. Mouse clicks focus a column directly. Every divider resizes only its column.

Right-click a client-owned machine or any tab in the tabs column to rename that exact row. Provider-owned machine renames remain capability-gated and versioned by the provider. Client-owned machine names last for the current process only; tab names remain session state.

The static catalog shows `+ ssh host`. It discovers concrete aliases from `Host` directives in `~/.ssh/config` and recursively follows `Include` directives. Wildcard and negated patterns are omitted. Type while the native picker is open to filter large host catalogs, then use Up/Down and Enter. Large pickers have the same wheel, track-click, and thumb-drag scrollbar as other native overlays. `Add SSH host…` accepts `cmux-lawrence`, `user@host`, or the familiar `ssh cmux-lawrence` spelling. Either path adds an SSH target for the current process and connects to its `main` session. SSH performs final config resolution, so aliases retain their configured hostname, user, port, proxy, and identity settings. Temporary targets and renamed machine labels are not written to configuration. To keep `cmux-lawrence` across launches, add a concrete `Host cmux-lawrence` entry to `~/.ssh/config`; the picker discovers it on the next launch.

`+ new vm` remains capability-gated. Configured `machine_sidebar.create_sources` enable a prototype native source picker whose new rows point back to the current mux. This validates Docker and microVM provider UX without running a provider or provisioning infrastructure.

## Static targets

Unix targets connect directly to another local cmux control socket. Use an absolute socket path because configuration paths do not pass through a shell.

SSH targets use the same managed lifecycle as `cmux-tui ssh`. The client resolves the destination through OpenSSH, probes the configured remote binary, and then opens the remote link. The link starts the named headless mux and its sidecar when they do not exist, so the session does not need a separate supervisor just to connect.

```text
ssh -T [-p PORT] -o BatchMode=yes -o StrictHostKeyChecking=yes -o ForwardAgent=no -o ForwardX11=no -o ClearAllForwardings=yes [-i IDENTITY_FILE] [USER@]HOST BINARY remote-probe --json
```

The remote `binary` defaults to `~/.local/bin/cmux-tui` and must be a shell-safe path. Packaged releases can install their pinned npm build there when the probe reports a missing or recognized incompatible binary. A legacy binary that cannot answer `remote-probe` requires an explicit `cmux-tui ssh HOST --upgrade`. Development and other source builds cannot replace the remote automatically; install the exact matching build at `binary` instead.

Connections stay warm in a bounded pool after a switch, so returning to a recently used machine is instant: the client reuses the open connection, skips re-preparation, and keeps painting the current machine instead of a connecting interstitial. The pool keeps the most recently used connections, 5 by default; `CMUX_TUI_WARM_MACHINES` (minimum 2) changes the bound. A pooled connection whose stream died reconnects fresh instead of being handed back. A machine that pauses under an attached client presents as sleeping ("sleeping — press any key to wake"); the first keystroke resumes it through the normal switch, with the provider's live `connection_progress` messages (capability `connection-progress-v1`) shown in the interstitial while it opens.

The client never prompts for a password or new host key inside the TUI. The target must already be trusted in local `known_hosts`, and a key or SSH agent must authenticate it. Agent forwarding, X11 forwarding, and all port forwarding are disabled. Switching machines drops the old local connection lease after the replacement commits. The remote mux stays available for later attachment. `cmux-tui relay` remains a low-level direct protocol diagnostic and is not the rail connection path.

See [Configuration](configuration.md#machines) for the full schema and examples.

## Dynamic providers

A dynamic provider supplies scopes, machines, lifecycle actions, and transports without adding provider logic to the TUI. Choose exactly one startup transport:

```bash
cmux --machine-provider /run/cmux/provider.sock
cmux --machine-provider-command /opt/cmux-provider --profile production --
cmux --cloud
```

The direct-command form treats every value through the terminating `--` as one literal argument. It does not use a shell. cmux appends `control` to the long-lived provider process and `stream` to each machine transport process.

`--cloud` runs OpenSSH against `cmux.cloud` by default. `--cloud-host`, `--cloud-user`, `--cloud-port`, and `--cloud-identity` override the destination. The connector uses one private SSH ControlMaster per provider generation and runs exactly `cmux provider control` for the catalog connection and `cmux provider stream` for each machine connection. The SSH server must implement those two commands.

A local `--cloud` client appends the configured `machines` array to the provider catalog. Provider machines use low process-local keys and local entries use the upper half of the key space. A provider refresh cannot replace an active local session. Switching back to a provider machine opens a fresh provider ticket.

`+ ssh host` has two capability-gated owners. When the provider negotiates `connect-external-machine-v1` and sets the current snapshot's `connect_external_machine` bit, the prompt accepts a host address or pairing code and sends it unchanged as an opaque provider mutation. The provider enrolls and selects the returned machine; the TUI refreshes the catalog and opens it through the normal machine-switch path. The pairing code is bounded, never shell-evaluated, and redacted from debug output. Exact retries use the same mutation id and receive the provider's idempotent result.

When provider-owned connect is unavailable, the local Cloud overlay preserves the static behavior: a temporary `host` or `user@host` target uses the caller's local SSH config, keys, agent, and `known_hosts`. Those local target details never enter provider requests.

Unix-socket and direct-command provider modes are provider-only and reject a simultaneous `machines` array. The native TUI reached by `ssh cmux.cloud` uses Unix provider mode and has no access to the caller's local SSH credentials. It shows provider-owned connect only when both protocol signals are present.

Each connection generation receives a new client-generated bearer. The bearer travels only in the first provider protocol message and later machine transport handshakes. It is never placed in process arguments, environment variables, or diagnostics. Dropping or reconnecting the provider terminates its child processes and removes its private SSH control directory.

See [Configuration](configuration.md#dynamic-machine-provider) for persistent cloud settings and [Machine Provider Contract](../spec/machine-provider.md) for the transport boundary.

## Run with npm

Packaged clients install their pinned remote binary after the compatibility probe:

```bash
npx cmux
```

Set the target's `session` to `agents`. The first managed connection starts that session on demand.

The local `npx cmux` process opens SSH only when that machine is selected. It verifies the remote package and protocol, installs a missing or incompatible packaged binary, then starts or reuses the remote protocol-v12 session. Source builds must install the exact matching binary themselves; `--no-install` disables automatic installation. A legacy executable that cannot answer the probe requires `--upgrade`.

For a direct transport check, the equivalent relay is:

```bash
ssh -T dev@buildbox /home/dev/.local/bin/cmux relay --session agents
```

This command emits raw JSON-lines protocol traffic, not a second TUI. It checks an already running mux and bypasses the managed probe, startup, identity pinning, and reconnect path.

## Share a local machine through Cloud

Start a persistent local session in one terminal or service supervisor:

```bash
npx cmux server start --session agents
```

First verify Cloud host trust and authentication once, then exit back to your local shell. Use the same resolved host, user, port, and identity that the agent will use:

```bash
ssh cmux.cloud
# With overrides: ssh -p <port> -i <identity> <user>@<cloud-host>
```

Quit the Cloud TUI so SSH returns to your local shell. This interactive step trusts the host and confirms that an SSH agent or unencrypted key can authenticate. The long-lived agent uses `BatchMode=yes`, so restart fails and retries instead of hanging on a password, passphrase, or host-key prompt.

Start the outbound agent from another interactive local terminal with `/dev/tty`:

```bash
npx cmux machine-agent --session agents
```

The agent fails closed without a controlling terminal, including on reconnects where the broker does not emit a pairing code.

The agent runs the exact remote command `cmux machine register`. The first successful registration prints a short one-time pairing code. In the TUI reached by `ssh cmux.cloud`, choose `+ ssh host` and enter that code.

The connection is outbound only. The agent opens no listener and changes no shell or SSH files. It multiplexes Cloud streams onto the selected local protocol-v12 session, reconnects with bounded backoff, and preserves active streams during a server-requested software generation migration.

The stable random machine id and secret live in a private mode-0600 identity file under the cmux config directory. The containing directory is mode 0700. Pairing codes are never persisted. Use `--state`, `--cloud-host`, `--cloud-user`, `--cloud-port`, or `--cloud-identity` when the defaults do not match the local setup. See [Machine Agent Contract](../spec/machine-agent.md) for bounds and migration rules.
