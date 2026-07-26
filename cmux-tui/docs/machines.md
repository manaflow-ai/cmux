# Machines

The optional machine rail adds a connection layer to the left of the existing workspace rail. Selecting a machine replaces the attached cmux session while the client, rail layout, mouse handling, and workspace rendering stay local.

The feature is disabled by default. It activates when `machine_sidebar.enabled` is `true` or the `machines` array contains at least one valid entry. An active static catalog always starts with the current local session, labeled with the local hostname and `local`, followed by configured Unix-socket and SSH targets. A configured machine with id `current` is skipped because that id belongs to the local entry.

## Layout and input

The machine list and built-in workspace list use the same rail renderer, selection treatment, two-line entries, and divider. Each right divider has an independent drag width. `machine_sidebar.width` and `sidebar.width` provide their separate starting widths; their `max_width` settings provide separate drag limits. Both rails preserve at least 40 columns for pane content. When the terminal cannot fit two 10-column rails and the content minimum, cmux hides the machine rail first.

`Ctrl-b S` focuses the workspace rail. Left or `h` moves to the machine rail, and Right or `l` returns to the workspace rail. Up/Down or `k`/`j` changes the selected machine. Home, End, PageUp, and PageDown move through long catalogs. Enter connects to the selected machine or invokes the selected footer action. Esc returns focus to the active pane. Mouse clicks focus either rail; a machine switch occurs on release over the same machine row. Drag either divider to resize only that rail. Wheel input scrolls the rail body, or the footer when a very short terminal clips its actions.

The static catalog shows `+ Connect machine`. It accepts one `host` or `user@host` without whitespace, adds an SSH target for the current process, and connects to its `main` session. This temporary target is not written to configuration. `+ New VM` is capability-gated and does not appear for the static catalog.

## Static targets

Unix targets connect directly to another local cmux control socket. Use an absolute socket path because configuration paths do not pass through a shell.

SSH targets start this process:

```text
ssh -T -o BatchMode=yes -o StrictHostKeyChecking=yes -o ForwardAgent=no -o ClearAllForwardings=yes [-p PORT] [-i IDENTITY_FILE] -- [USER@]HOST 'BINARY' relay --session SESSION
```

The remote session must already be running. The remote `binary` must resolve in a noninteractive SSH login and defaults to `cmux-tui`. `relay` copies protocol bytes between stdio and that session's Unix socket. SSH owns host verification, authentication, encryption, and network transport; relay adds no authentication. The client never prompts for a password or new host key inside the TUI. The target must already be trusted in local `known_hosts`, and a key or SSH agent must authenticate it. Agent forwarding and all port forwarding are disabled.

See [Configuration](configuration.md#machines) for the full schema and examples.

## Dynamic providers

A dynamic provider supplies scopes, machines, lifecycle actions, and transports without adding provider logic to the TUI. Choose exactly one startup transport:

```bash
cmux-tui --machine-provider /run/cmux/provider.sock
cmux-tui --machine-provider-command /opt/cmux-provider --profile production --
cmux-tui --cloud
```

The direct-command form treats every value through the terminating `--` as one literal argument. It does not use a shell. cmux appends `control` to the long-lived provider process and `stream` to each machine transport process.

`--cloud` runs OpenSSH against `cmux.cloud` by default. `--cloud-host`, `--cloud-user`, `--cloud-port`, and `--cloud-identity` override the destination. The connector uses one private SSH ControlMaster per provider generation and runs exactly `cmux provider control` for the catalog connection and `cmux provider stream` for each machine connection. The SSH server must implement those two commands.

A local `--cloud` client appends the configured `machines` array to the provider catalog. Provider machines use low process-local keys and local entries use the upper half of the key space. A provider refresh cannot replace an active local session. Switching back to a provider machine opens a fresh provider ticket.

`+ Connect machine` has two capability-gated owners. When the provider negotiates `connect-external-machine-v1` and sets the current snapshot's `connect_external_machine` bit, the prompt accepts a host address or pairing code and sends it unchanged as an opaque provider mutation. The provider enrolls and selects the returned machine; the TUI refreshes the catalog and opens it through the normal machine-switch path. The pairing code is bounded, never shell-evaluated, and redacted from debug output. Exact retries use the same mutation id and receive the provider's idempotent result.

When provider-owned connect is unavailable, the local Cloud overlay preserves the static behavior: a temporary `host` or `user@host` target uses the caller's local SSH config, keys, agent, and `known_hosts`. Those local target details never enter provider requests.

Unix-socket and direct-command provider modes are provider-only and reject a simultaneous `machines` array. The native TUI reached by `ssh cmux.cloud` uses Unix provider mode and has no access to the caller's local SSH credentials. It shows provider-owned connect only when both protocol signals are present.

Each connection generation receives a new client-generated bearer. The bearer travels only in the first provider protocol message and later machine transport handshakes. It is never placed in process arguments, environment variables, or diagnostics. Dropping or reconnecting the provider terminates its child processes and removes its private SSH control directory.

See [Configuration](configuration.md#dynamic-machine-provider) for persistent cloud settings and [Machine Provider Contract](../spec/machine-provider.md) for the transport boundary.

## Run with npm

Install cmux on a remote Linux or macOS machine so SSH has a stable executable path, then start a named headless session there:

```bash
npm install --global cmux
command -v cmux
cmux --headless --session agents
```

Keep the headless process under your normal service supervisor when it must survive logout. Put the absolute path printed by `command -v cmux` in the target's `binary` field and set `session` to `agents`. After adding that target to the local config, start the client normally:

```bash
npx cmux
```

The local `npx cmux` process renders both rails and opens `ssh -T` only when that machine is selected. The remote process serves workspaces and terminals through its existing protocol-v9 session.

For a direct transport check, the equivalent relay is:

```bash
ssh -T dev@buildbox /home/dev/.local/bin/cmux relay --session agents
```

This command emits raw JSON-lines protocol traffic, not a second TUI. Normally the machine connector owns it.

## Share a local machine through Cloud

Start a persistent local session in one terminal or service supervisor:

```bash
npx cmux --headless --session agents
```

First verify Cloud host trust and authentication once, then exit back to your local shell:

```bash
ssh cmux.cloud
```

Quit the Cloud TUI so SSH returns to your local shell.

Start the outbound agent from another local terminal:

```bash
npx cmux machine-agent --session agents
```

Use the interactive SSH command once to trust the host and confirm that an SSH agent or unencrypted key can authenticate. The long-lived agent uses `BatchMode=yes`, so restart fails and retries instead of hanging on a password, passphrase, or host-key prompt.

The agent runs the exact remote command `cmux machine register`. The first successful registration prints a short one-time pairing code. In the TUI reached by `ssh cmux.cloud`, choose `+ Connect machine` and enter that code.

The connection is outbound only. The agent opens no listener and changes no shell or SSH files. It multiplexes Cloud streams onto the selected local protocol-v9 session, reconnects with bounded backoff, and preserves active streams during a server-requested software generation migration.

The stable random machine id and secret live in a private mode-0600 identity file under the cmux config directory. The containing directory is mode 0700. Pairing codes are never persisted. Use `--state`, `--cloud-user`, `--cloud-port`, or `--cloud-identity` when the defaults do not match the local setup. See [Machine Agent Contract](../spec/machine-agent.md) for bounds and migration rules.
