# cmux-next-host bridge: security analysis

`cmux-next-host run` bridges the phone into the cmux-next app running on the
same Mac (`--bridge auto|on|off`, default `auto`). This is a remote relay into
the app's daemon and its acpmux agent service, so it follows the repo's
remote-relay rules (`skills/cmux-socket-policy/references/remote-relay-authorization.md`):
default deny, an explicit allowlist, no command-bearing params, scoped IDs, and
policy tests.

## Who is on the other end

The phone reaches the host over a WebRTC link that the backend only
establishes for the account that paired this Mac (host token, per-session
family checks, revocation; see `PROTOCOL.md` §5). The phone is the Mac owner's
own device. In standalone mode the same link already gets full terminals
(`$SHELL -l`) and agents on this Mac. The bridge must not give the phone more
than that, and must not let a compromised phone or link widen it.

## What the bridge talks to

| Target | How it is found | Local power |
| --- | --- | --- |
| cmux-next daemon | `$(getconf DARWIN_USER_TEMP_DIR)cmux-tui-<uid>/cmux-app[-<tag>].sock`, or `--daemon-socket` | A same-uid Unix client is fully trusted by the daemon (it includes admin commands such as `shutdown-daemon`, `pairing-response`, `run`). |
| acpmux | `~/.acpmux[/tags/<tag>]/acpmux.sock`, or `--acpmux-socket` | The Unix socket has acpmux's `Local` origin: start any harness, any cwd, MCP servers, peers, import/export. |

Both sockets give far more than the phone needs. The bridge therefore never
forwards phone JSON. Each phone RPC (`term.*`, `agent.*`) is mapped in host
code to fixed daemon/acpmux calls with host-built params, and every outgoing
call is checked by `src/bridge/policy.ts` before it is written (a second,
independent gate). Anything not listed there is refused.

## Allowlist

Daemon (`DAEMON_ALLOW`), with the only fields each may carry:

| Command | Fields | Why |
| --- | --- | --- |
| `identify`, `set-client-info` | `name`, `kind:"frontend"`, `capabilities`, `device_kind`, `device_name` | handshake |
| `subscribe` | `tree_events:"deltas"` | terminal list changes made on the Mac |
| `list-workspaces` | none | terminal list (pty tabs only are exposed) |
| `attach-surface` | `surface`, `mode:"bytes"` | mirror a terminal; no `cols`/`rows`, so attaching never resizes |
| `set-size-counts` | `surface`, `counts:false` only | the phone's view never takes the Mac's grid |
| `send` | `surface`, `bytes` (base64, 1 MiB) | typing into an existing terminal |
| `detach-attached-view` | `surface`, `lease` | end a mirror |
| `new-tab` | none | a new tab running the user's default shell |
| `close-surface`, `rename-surface` | `surface` (+ `name`) | phone terminal list actions |

acpmux (`ACPMUX_ALLOW`): `initialize` (empty client capabilities),
`_acpmux/watch`, `_acpmux/sessions`, `_acpmux/harnesses`, `_acpmux/models`,
`session/new` (`cwd`, `mcpServers: []`, `_meta.acpmux.{harness, model}` only),
`_acpmux/attach`, `session/prompt` (text and image blocks only),
`session/cancel`, `_acpmux/kill`, `_acpmux/permission_respond`,
`session/set_model`, `session/set_mode`, `_acpmux/rename`.

## The three questions

### Can it execute commands or open content on local objects?

- **Typing into a terminal (`send`).** Yes, by design: the phone types into
  the user's own shell, exactly what the standalone host's PTYs already
  allow. The bridge adds no new execution surface. It can only reach
  terminals that already exist on this Mac, and only through the
  phone's own paired, family-checked link.
- **Spawning terminals.** Only `new-tab` with no params. The daemon runs
  the user's default shell (`SHELL`) in the inherited working directory.
  `shell_args`, `cwd`, `env`, `argv`, `command`, `terminal_id` and launch
  specs are denied on every command. `run`, `create-terminal`,
  `create-surface-with-receipt`, `apply-layout`, `split`, `new-pane*` and
  `new-screen` are not listed at all. `term.create` with a `cwd` is refused
  with `unsupported`. The daemon runs on this Mac, which is the intended
  target: there is no other host a spawn could fall back to (verified live
  on mini-cmux15, see below).
- **Agents.** `session/new` starts a harness that acpmux already knows
  (claude, codex, ...) with no extra argv or env. `mcpServers` must be empty,
  so the phone cannot make acpmux spawn an MCP server command. `cwd` must be
  an existing directory inside `$HOME` (`safeCwd`). `_meta.acpmux` may carry
  only `harness` and `model`, so no policy, preset, env or person key can be
  passed. Prompts carry text and images only. `resource` blocks (which can
  name local files) are refused.
- **Permission approvals.** acpmux accepts an "allow" only from a
  connection that presented the app's per-launch person key, which the
  bridge does not have. The phone can deny or cancel; an allow returns
  acpmux's `permission.person_required` error. `_acpmux/set_policy`,
  `_acpmux/set_rules` and `_acpmux/defaults` are denied, so the phone cannot
  widen what agents may do without asking. acpmux also refuses permission
  widening through `session/set_mode` without the person key.
- **Opening content.** Browser verbs are not bridged. The Mac's browser
  tabs are frontend-rendered and the daemon cannot stream them. The host
  keeps its own Chrome provider for `browser.*`.

### Can it mutate or destroy objects it does not own?

The daemon and acpmux run as this macOS user and hold only this user's
terminals and sessions. All are the phone owner's objects. IDs are scoped:

- `terminalId` must be `s<surface>` for a surface that is currently a
  **pty tab** in the daemon's tree. Browser, conversation and unknown
  surfaces are `not_found`. Ref forms and other shapes are rejected.
- Agent session ids are passed to acpmux, which only knows this user's
  sessions. `agent.list` hides sessions that live on acpmux peers.
- `term.close` and `agent.close` act on the user's own objects, as the
  existing mobile daemon-lane policy already allows (`close-surface`).

### Does it read local state the phone has no business seeing?

The phone sees what the cmux-next window shows:
- the terminal titles, cwd and grid;
- the terminal bytes (the scrollback replay included);
- agent transcripts, including tool input and output.

The bridge does not call `list-terminals` or `resolve-terminal`, which expose
`launch_spec` (argv, env). It does not read daemon or acpmux config, tokens,
peers, exports or Chief homes. No daemon admin or local-admin command is
reachable.

## Sizing

The phone never resizes the Mac's terminal. Attaches carry no size, the
bridge's view is set to `counts:false`, and `term.resize` from the phone is
answered with the Mac's current grid (`term.updated`) instead of resizing.
The phone renders at the Mac's grid.

## Tests

`test/bridge.test.ts`:
- **Daemon policy:** denies `run`, `create-terminal`,
  `create-surface-with-receipt`, `apply-layout`, `split`, `shutdown-daemon`,
  `pairing-response` and `agent-session-*`. Also denies `new-tab` with `cwd`,
  `shell_args` or `env`; render mode or sized attaches; `counts:true`; wrong
  id types; extra fields; and prototype keys.
- **acpmux policy:** denies peers, import/export, policy/rules/defaults and
  shutdown. Also denies `session/new` with MCP servers or extra `_meta`
  fields, `resource` prompt blocks, and non-empty client capabilities.
- **Bridges against fake daemon and acpmux sockets:** owned-target allow
  cases, refusal of browser and malformed terminal ids, `cwd` refusal,
  no resize on the wire, and transcript mapping.
