# cmux next: remote conversations on a paired server (relay analysis)

Status: revision 15 (lane 10, server), after the security review of bd5ceb79a51 (1 P0, 4 P1,
5 P2), with the coordinator's decisions D-A and D-B of 2026-10-04. No code yet; the review agent
re-checks this revision before any code. Decisions D1 and D2 of 2026-10-04: the MacBook opens the daemon
conversations of a paired Mac mini over lane 12's `cmux link` overlay; the server is a
`MachineRegistry` kind `paired {install_id, name, path_state}`. This is the analysis that
`skills/cmux-socket-policy/references/remote-relay-authorization.md` requires before code.
Decided: D-A, the remote approval minimum with no waiver (section 6); D-B, a distinct
`remote_<install>` participant added at pairing (section 5); D-C, a paired device is the same
person; D-D, offline revocation limits 24 h / 72 h; D-E, the daemon decides every tool call (the PreToolUse fast-allow hook was dropped after the
probes, rev 10).

## 1. Threat model

- The remote party is a paired install of the server's owner (server.md 6.2). It is treated as
  a **compromised client**: a stolen laptop, a malicious process of the laptop user, a forged
  frame. It never inherits local trust.
- Protected on the server: terminals, workspaces, agent sessions and their tools, files,
  localhost services, the store, tokens and keys, pending pairing codes, memory files,
  automations, and the user's other data.
- A message to the owner's Chief is an instruction to a model with the full tool catalog. That is
  remote execution through the model and is handled as such (section 6).

## 2. Transport position and identity

- `cmux link` (lane 12, not built yet) is the only process that reaches the daemon for a remote
  peer. It connects to a **separate daemon remote-relay entry** (its own Unix socket, 0600), never
  to the admin socket. The daemon accepts a connection there only after it checks the peer with
  the audit token (`LOCAL_PEERTOKEN`, macOS) or `SO_PEERCRED` (Linux): same uid, and on macOS the
  cmux team code signature of the link binary (on Linux, `SO_PEERCRED` checks the uid only; the
  socket's 0600 mode and folder carry the rest). There is no env or debug bypass, also not for
  ad-hoc DEV builds (a DEV build without a team signature cannot serve remote peers).
- Identity: WireGuard authenticates the peer static key; the link maps it to the install id
  through the pairing record (allowed IP: the /128 from the install id) and sends the **stamp**
  `{install_id, user_id, wg_key}` as the first out-of-band record of each stream that
  `link.dial {host, service: "daemon"}` opens. The daemon trusts the stamp and nothing else.
  No stamp, a stamp on the admin socket, or a stamp from a process that fails the peer check:
  the stream is closed before the first frame.
- New transport kind `ClientTransport::RemoteRelay(stamp)` beside Unix and WebSocket.
  `is_unix()` is **false** for it, so `require_local`, `url_open::start` and
  `loopback_forward::try_handle` refuse it by their existing checks. Tests pin this (section 9).
- Principal: `conversation_principal` becomes an enum `Local | Agent(participant) |
  Remote(stamp)`. An absent principal is refused; there is no default to `LOCAL_USER` for any
  connection on the remote entry.

## 3. Gate position (frame level, before every router)

`handle_connection_message` today routes resource-protocol, `loopback-*` and
`scheduler.dispatch` frames before the command parse, and `UrlOpen` runs first in
`handle_request_with_cancellation`. The remote gate therefore runs **first in
`handle_connection_message`** for `RemoteRelay` connections, before the resource router,
loopback, scheduler and URL-open paths:

- every resource-protocol, `loopback-*`, `scheduler.*`, `url-open` and binary frame: refused;
- every command not on the allowlist (section 4): refused;
- an allowlisted command: params checked (section 7), then dispatched.

A second filter runs at the **outbound writer** of a remote connection: only allow-listed event
kinds for owned conversations leave it (section 8). Nothing reaches the remote writer directly.

## 4. Allowlist (default deny, exact names, never prefixes)

| Command | Remote | Rule |
| --- | --- | --- |
| `identify` | yes | reply built from a remote-only struct: protocol version and the conversation capabilities; no socket path, pid, state dir, hostname, window or client ids |
| `set-client-info` | yes, reduced | accepts only `name` and `capabilities` from an allowlist (`local-conversations-v1` and its read features); refuses any other capability (for example `loopback-forward`); ignores `user_id`, `display_name` and every `device_*` field; identity is only the stamp |
| `subscribe` | yes, reduced | no `surface` and no `tree_events` params (refused); the stream gets only section 8 events |
| `conversation-list` | yes | owned conversations only (section 5) |
| `conversation-snapshot`, `conversation-history` | yes | owned `conversation` only |
| `conversation-op` | partly | kinds `message.send`, `message.edit`, `message.retract`, `reaction.add`, `reaction.remove`, `read_cursor.set`; approval kinds and any other kind refused by name |
| `conversation-typing` | yes | owned conversation |
| `conversation-create`, `participants.add`, `title.set` | no (v1) | |
| `conversation-search`, `conversation-tabs`, `new-conversation-tab` | **no** | named here because they share the prefix; nothing is allowed by prefix |
| `conversation-agent-token`, `conversation-bind` | **never** | credential minting and binding |
| all other commands (workspace, screen, pane, tab, terminal, browser, raw, send-keys, write, lifecycle, plugin, journal, notification, pairing, session, url-open, loopback, scheduler) | **never** | table test over the daemon's whole command list; a new command is denied until added here with an analysis |

## 5. Owned objects and the remote participant (D-B)

- Owner scope (v1): the stamp's `user_id` must equal the server **owner** (the `user` of the
  stored pairing record); a peer that is not the owner owns nothing. The store's list, snapshot
  and history do no participant check today, so the gate applies the clause below.
- Unknown and unowned conversation or message IDs give the **same** error (`remote_denied`), so a
  peer cannot probe. Ref forms, prefixes and names are refused.
- **Remote participant (D-B).** Each paired install has a distinct participant
  `remote_<install>` with kind `human` and a new field **`person: "user_local"`** (the same human
  as the server's own user; display name "<owner name> (<device name>)").
  - **Same person (D-C, decided yes):** the wake rule (home.md 2: with more than one human
    the Chief wakes only on a mention, a reply or a DM) and the participant budget
    (`MAX_PARTICIPANTS`) count distinct **persons**, not participant ids. A paired device therefore
    does not change how the Chief answers the owner's plain local messages, and devices do not use
    up the budget.
  - **Which conversations:** every conversation whose participants include `user_local`, at
    pairing time and later: a conversation created afterwards with `user_local` gets the
    `remote_<install>` participant of every active paired install in the same commit.
  - **Cap (P3-E):** `MAX_PARTICIPANTS` counts entries, so paired installs are capped: at most
    8 paired installs per server (proposal); pairing a ninth is refused with a clear reason.
  - **Who adds and removes it:** new system-only ops `participants.add_system` and
    `participants.remove_system`, accepted only from the daemon's own pairing and revocation path
    (principal `System`), refused from local clients, agents and remote peers. A conversation at
    its person budget refuses the add, and pairing reports it.
  - **Remove:** `participants.remove_system` takes the participant out of the list; its past
    messages stay with author `remote_<install>` and show "removed device"; nothing can be sent
    or edited as that participant again.
  - The remote actor is always `remote_<install>`, **never** `user_local`; a request that names
    another actor gives `actor_mismatch`. Authorship is per device: a remote peer can edit or
    retract only messages its own `remote_<install>` sent (`not_author` otherwise).
  - Every remote op and message carries `origin: {kind: "remote", install}` in the op ledger and on
    the message. This changes the `cmux-conversation` wire types and the conformance corpus that
    the cloud `ConversationDO` replays, so the change lands with a coordination line and the corpus
    update in the same push, agreed first with the `ConversationDO` owner (the backend lead)
    through a coordination line that names both new fields, `origin` and `person`.
- Owned conversation: `remote_<install>` is a participant and the stamp's `user_id` is the server
  owner. The gate checks this for list, snapshot, history, typing and ops.

## 6. Remote prompts to agents (D-A no waiver; D-E to D-J; rev 15)

A `message.send` from a remote principal into a conversation with an agent starts a
**remote-origin prompt chain**. Every rule fails closed: when any part of the gate is missing,
crashed, slow or unsure, the tool does not run.

1. **Fixed minimum.** In a remote chain every side-effect tool needs an approval: every MCP write,
   Bash and other shell, file writes, child agent spawn, `automation.deploy`, settings,
   `CLAUDE.md` and hooks edits, every scheduled automation change. Reads outside the read root
   need an approval too, because their output returns to the remote as text. A tool the gate
   cannot classify needs an approval. Nothing lowers the minimum (the remote, the model, a
   setting, `CLAUDE.md`, a hook, a permission mode, a session policy or rule); there is no waiver.
2. **Read root (P2-J, P2-Q).** The read root is a **separate folder** that holds only the Chief's
   memory files and the **section 8 projections** of owned conversations (never the raw
   conversation files, which hold redacted fields such as `work.preview`, `acp_session`, other
   cursors and non-owned conversations) and contains no deny path (for another agent: its session's
   workspace root, under the same rules). Reads without an approval are allowed only there. The
   deny list is a second layer: `state/`, `*.token`, `.claude/`, `.env*`, `~/.ssh`, the
   `MUX_AGENT_TOKEN_FILE` path, the pairing record and install keys always ask approval, and the
   acpmux home (its config and the WebSocket dashboard token) is never approvable for reads or
   writes in a remote chain.
   **Memory files (P2-3, D-M decided: reads ask).** In a remote chain, reads of the Chief's memory
   files (`LOG.txt`, `TREE/`) ask the human with a presence proof, because they can hold
   non-owned conversation content and local tool output. Follow-up: a memory projection in the
   read root (owned, remote-safe entries only) if these approvals turn out to be too frequent. For
   agents other than the Chief, dotfile reads (`.npmrc`, `.netrc`, credential JSON files and other
   dotfiles) ask too, except a reviewed list.
   - The daemon decides on the **real path**: `realpath`, then `F_GETPATH` on an opened descriptor
     for the file on disk, compared case-folded on case-insensitive volumes (APFS default), with
     `/var` and `/private/var` and `..` resolved. It denies when either the requested or the
     resolved path is in a deny area or outside the read root.
   - Static deny rules in the inline settings use absolute `//` patterns (relative patterns have
     no base there).
   - A Bash search (`grep`, `find`) over a folder that contains a deny path asks approval like any
     Bash call; inside the read root there is no deny path by construction.
3. **Own fresh process (acpmux design 3; P1-K, D-I decided).** A remote
   chain runs in its own Claude process and **never forks or resumes a local session** (acpmux
   `fork()` copies the harness, argv, permission policy, modes, config options and models, and
   `--resume --fork-session` brings the whole local transcript with its tool results). It starts
   fresh, always, with only the **remote projection** of the conversation's messages (section 8
   structs) as context; it does not resume earlier remote-chain sessions either (P2-N, D-L decided). The remote projection reaches the
   fresh process as its **first prompt over stdin**, never through argv (visible in `ps`, about
   1 MB limit); every earlier remote message in it is wrapped in rule 10 delimited blocks, because
   it can carry injection text (P3-N). Revocation
   archives that install's remote-chain sessions for good, so a re-paired device starts from the
   remote projection only. Its configuration is built from scratch (rule 4): pinned `claude`, empty extra argv,
   policy `daemon`, no copied modes, config options or models. Cancel and revocation kill its
   process group through the agent host. Known gap: a child that an approved Bash call starts with
   `setsid` leaves the group and can survive cancel; it stays inside the Bash sandbox (12b), and
   the approval text says "an approved shell call runs in the sandbox and can create work that
   persists".
4. **Clean configuration (acpmux design 1, 5; P2-L, P3-I).** A remote-chain session starts with
   `--setting-sources ""`, `--settings` and `--mcp-config` passed as **inline JSON** (never as
   files a same-uid tool could rewrite), and `--strict-mcp-config`. The settings carry only:
   bypass disabled per session (`permissions.disableBypassPermissionsMode: "disable"`,
   `permissions.defaultMode: "default"`, `permissions.ask: ["*"]`), the cmux-tui status hooks and
   the remote-log hooks (rule 11).
   There is no fast-allow hook (probe, Claude Code 2.1.289: `ask` beats a hook allow, so such a hook
   is dead code); the daemon auto-answers reads through the permission step. They set no `enabledPlugins` and no MCP-enable keys. The MCP config names only the
   daemon's servers. **Every tool goes through the daemon (P1-M, D-K decided):** the daemon auto-answers reads inside
   the read root with no human round trip, denies the deny paths, and asks the human (with a
   presence proof) only for side effects. In
   `default` mode Claude Code runs some tools (for example Read inside the working folder) with no
   permission step, so the inline settings also carry:
   - `permissions.deny` for every rule 2 deny path (as `Read(...)`, `Edit(...)`, `Write(...)`
     rules) and for `Skill` and `SlashCommand`;
   - `permissions.ask: ["*"]` over the closed `--tools` list (Claude Code 2.1.289: `Read`, `Edit`,
     `Write`, `Bash`, `WebFetch`, `WebSearch`, `Agent`, `AskUserQuestion`, `ExitPlanMode` and the
     daemon's MCP tools; no `Task`, `Glob`, `Grep` or `TodoWrite` exist there), so each call reaches
     the permission step and the daemon, which allows reads inside the read root at once.
   - **No secrets on argv (P2-O):** the inline JSON is visible in `ps`, so it carries no token or
     key. The daemon's hook and MCP servers authenticate the session by peer credentials, or read a
     secret from the environment, or the config goes through `--mcp-config /dev/fd/N`.
   - **No mode changes (P2-O):** acpmux forwards `session/set_mode` straight to Claude as
     `set_permission_mode`, and disabled bypass does not stop `acceptEdits` (edits with no
     permission step). For a remote-chain session acpmux refuses `session/set_mode` and
     `set_config_option` from every client.
   - **Web tools (P2-c):** `WebFetch` and `WebSearch` are side effects and ask the human (a
     `WebFetch` to `localhost` reaches local services).
   - **No model change:** `session/set_model` is refused for a remote-chain session, like
     `session/set_mode` and `set_config_option`.
   - **Classified interactive tools:** `AskUserQuestion` (its answer goes through the bound
     approval path, 12a) and `ExitPlanMode` (asks) are in the tool table.
   - **Narrow working folder (P1-M):** the remote-chain process starts in a folder that holds only
     the memory and conversation files (the read root), not all of `$MUX_HOME`. The probe lists
     which built-in tools skip the permission step.
   - **No env in the JSON (P3-L):** the mux host's `writeSessionDir` puts an `env` block
     (`MUX_HOME`, socket paths, `ACPMUX_*`, `CMUX_MCP_COMMAND`) into settings; for a remote chain
     the inline settings and MCP JSON carry no env values, tokens or keys. Those values go only in
     the process environment.
   - **What a clean start drops (P3-M):** with `--setting-sources ""` the session's
     `.claude/settings.json` (memory hooks, `PATH` for mux) and probably `CLAUDE.md` (the Chief's
     system prompt) do not load. The agent host passes the Chief's prompt with
     `--append-system-prompt`, puts the remote-log hooks in the inline settings, and sets the
     subrouter base URL (the model route that `claude-sr` gave) in the process environment.
   - **Agent** (the subagent tool) is a child spawn under rule 1: each call asks the daemon; only the
     built-in general subagent type is allowed, and it runs under the same settings and deny rules. User and repository `permissions.allow` rules, hooks and `.mcp.json` never
   load. The Claude Code version is pinned and checked at spawn; profile wrappers (for example
   `claude-sr`) and extra argv are refused. Writes to the gate's inputs (acpmux and daemon
   configuration, the hook binary, the pinned Claude install) are never approvable in a remote
   chain.
5. **Gates before code (P3-H, P1-L).** Probes on the pinned version must show, before any code:
   - `disableBypassPermissionsMode` from inline `--settings` refuses bypass. Fallback:
     `--permission-mode default` on every remote spawn and refusal of
     `--dangerously-skip-permissions`.
   - user skills with `allowed-tools: Bash`, custom commands with `allowed-tools` or `!` lines,
     agent definitions with `permissionMode: bypassPermissions`, plugins (hooks, MCP), and managed
     settings, `managed-mcp.json` and managed hooks do **not** let a tool run without the daemon,
     and no plugin hook runs.
   - `ask` overrides the default auto-allow inside the working folder for Read, and the
     `permissions.deny` rules hold.
   - the built-in general subagent cannot call `Skill`, cannot read the deny paths, and sends its
     permission requests to the daemon; `--setting-sources ""` hides user and project agent types.
   - no user or project `CLAUDE.md` loads (its `@` imports would pull files with no tool call).
   - a **closed `--tools` list** per pinned Claude version, with `permissions.ask: ["*"]`; new tools
     are not offered until vetted. For Claude Code 2.1.289 the probe found `Agent` (not `Task`) and
     no `Glob`, `Grep` or `TodoWrite`; the exact table is copied from the probe's `system/init`
     output into code with the first code PR (proposed v1 set: `Read`, `Edit`, `Write`, `Bash`,
     `WebFetch`, `WebSearch`, `Agent`, `AskUserQuestion`, `ExitPlanMode` and the daemon's MCP
     tools; `Skill` and `SlashCommand` are not offered). The adapter is acpmux's `claude_stdio`
     (Claude stream-json, not an ACP adapter); if an ACP adapter is used later, its `fs/read` and
     `fs/write` also go to the daemon.
     As a backstop, at spawn the daemon reads the `tools` list from Claude's `system/init` and
     refuses the chain if any tool is not in its classified table (P2-R: this catches version drift and tools such as
     `ListMcpResources` and `ReadMcpResource`). Every MCP call (cmux screen reads, terminal and
     workspace state included) asks the human, except a reviewed list of read tools.
   - from the real pinned Claude Bash tool, `mux agents spawn` and a raw acpmux connect are
     refused, also after `setsid`, `nohup ... &` and a double fork (rule 12b OS boundary), and the
     macOS service escapes fail: `open -a`, `osascript`, `launchctl submit`.
   - the sandbox keys of rule 12b are honored as written, `autoAllowBashIfSandboxed: false` makes a
     sandboxed Bash call reach the permission step, and the canary fails closed when Seatbelt is off.
   - acpmux's `claude_stdio` (Claude stream-json) is the adapter, pinned with Claude; its handling of
     document blocks, slash commands and `@` is probed (rule 10). `fs/read_text_file` from an ACP
     adapter would bypass `handle_permission`; this is acceptable with `claude_stdio`, and the tests
     must cover it if an ACP adapter is added.
   - **D-J (decided): both.** in remote chains the `Skill` and `SlashCommand` tools
     and custom subagent types are denied by the daemon (only built-in tools and the built-in
     general subagent with no `permissionMode`), **and** the probe runs; at spawn, managed settings
     that add allow rules, hooks or MCP servers refuse the remote chain unless they are named on a
     reviewed list. This check is **mandatory**: the probe showed managed settings still load and
     managed hooks still run under `--setting-sources ""`.
6. **The decision is the daemon's (P1-H).** For a remote or unknown prompt, acpmux sends every
   `session/request_permission` to the daemon and **ignores** the session policy and rules
   (`MUX_POLICY`, which defaults to approve-all in the mux host, `--policy`, `acpmux session
   rules`, `/policy`, `/mode`). `--policy` is ignored on spawns in a remote chain, and policy or
   rules changes are refused for a tainted session for its whole life (12b).
7. **Allow once only (acpmux design 4).** In remote turns acpmux offers only `allow_once`. No daemon
   answer, a broken socket, or 10 minutes without an approval: deny, and the chain is cancelled.
   After a daemon or acpmux restart, pending remote approvals are denied and the chain is
   cancelled.
8. **Which agents (D-G).** Remote chains spawn only Claude Code in v1; any other harness and any
   auto or yolo mode is refused, also as a child.
9. **Origin (acpmux design 2, P3-K).** The origin is an ACP `_meta` field on the prompt that only
   the daemon can set: acpmux accepts `_meta.origin` only on prompts that arrive on its
   daemon-only Unix socket (0600, peer uid check, and on macOS the cmux team signature of the
   connecting binary) and strips it from every other path; an absent field means remote. acpmux's web listener and its peer and
   handoff paths stamp remote, or are disabled for remote-chain sessions. The origin is keyed by
   `(session, prompt id)`, stored durably with the prompt metadata and in the daemon store, and
   survives restarts and handoffs. No method can clear it. A prompt that contains any remote
   message is remote. The mark covers the prompt, its tool calls, its child sessions and its
   `[mux-event]` follow-ups; a later local message starts a new chain and never clears a running
   one.
10. **Remote text is data (P2-E, P2-M; probe results).** Remote text never goes as prompt text and
    never as an ACP embedded resource (acpmux's `claude_stdio` inlines resources as text, and `@path`
    in text is read with no tool call). It goes as a Claude **`document` content block** with a text
    source, next to a fixed instruction text written by the agent host. **Carrier (P2-1):** acpmux's
    `SESSION_PROMPT` mapping in `outbound.rs` knows only text, image and resource blocks, so the
    daemon sends an ACP block `{"type": "document", "_meta": {"cmux": {"conversation", "message",
    "install"}}, "text": ...}`, accepted only on the daemon socket; a new `outbound.rs` case emits
    the Claude block `{"type": "document", "source": {"type": "text", "media_type": "text/plain",
    "data": ...}, "title": "<conversation>/<message>"}` (ids only). An unknown block type in a
    tainted session refuses the prompt, also on the steer path (`steer_now`). The fixed prefix stays (a
    bare `/clear` as text runs as a command). The document title is built from ids only
    (conversation, message, install), never names. A probe on the pinned version shows that `/cmd`,
    `!x`, `@path`, a fake `[mux-event]` line and a fake "Message from user_local:" line inside a
    document block stay data; if a later version breaks this, the chain is refused until vetted.
11. **Hooks (D-H).** Only the injected hooks run (rule 4): the cmux-tui status hooks (journal events,
    no command built from the text) and the remote-log hooks (rule 4). No hook gets remote text as
    shell input. The mux host's memory hooks do not write `LOG.txt` or `TREE/` for a remote chain:
    the message and the reply go to a separate **origin-tagged remote log** (by file, no shell),
    which the memory view marks as remote and later local turns treat as untrusted. Moving any of
    it into `LOG.txt` or `TREE/` needs an approval with a presence proof.
11a. **How the remote chain posts (P3-J).** The remote-chain process posts as `agent_mux` through
    the same owner path as the local Chief: its replies go through the conversation outbox with the
    same idempotency keys and the same agent turn budget (home.md 2), and every message it posts
    carries `origin: remote`. The local Chief (one brain) learns of a remote chain only through the
    origin-tagged remote log and the conversation messages, never through shared process state.
12. **Approvals.** Each approval shows the exact command or call and its arguments, one approval
    per call. The card marks Bash commands that contain command substitution, `eval`, decoding
    (`base64 -d`, `xxd -r` and similar) or a pipe into a shell, because the visible text can hide the
    real target (for example `cat $(echo ... | base64 -d)`). The text says that an approved shell call runs as the owner inside the Bash sandbox
    (no local sockets, no network, writes only to the scratch folder) and can create work that
    persists there; an approved Edit or Write runs outside the sandbox with the owner's rights. Each approval needs a presence proof (lane 15: the presence key with
    Touch ID, or a second device). Approvals go through the cloud (lane 15), never over the link.
    **A LAN-only server (no cloud) denies every remote side effect;** reads inside the read root
    still work.
12a. **Answers are bound (P1-a).** Code facts: `hub/permissions.rs` and `server/requests.rs` accept
    `respond_permission` from every acpmux client (CLI `mux agents allow`, TUI, WebSocket, ssh
    peers), and `claude_stdio/outbound.rs` accepts `allow_always` when it was not offered and
    forwards `result._meta.updatedInput` to Claude. For a remote-tainted session (12b):
    - acpmux accepts an answer only on its daemon-only socket, and only with a daemon approval id
      that binds `(session, tool_use_id, sha256(rawInput))` to the presence proof (the hash over the
      exact `rawInput` bytes acpmux forwarded, echoed by the daemon in the answer);
    - `allow_always` is refused;
    - `updatedInput` is stripped, except the schema-checked answer field of interactive tools
      (`AskUserQuestion`); an `updatedInput` that differs from the shown input is refused.
12b. **Remote taint (P1-b, decided: permanent).** A session started for a remote chain is
    **remote-tainted for its whole life**. The taint is stored durably in acpmux session metadata,
    in the daemon store, and on the Claude `agentSessionId` too, and it stays after
    `SESSION_DELETE`, so an adopt or resume of the transcript after a delete is still tainted.
    Every prompt into a tainted session is remote, whatever its origin field says. The taint is set
    at `session/new` on the daemon socket; a remote prompt into an untainted session is refused.
    The taint is **never derived from a tag** (`_acpmux/tag`, `mux.parent`) or from an environment
    variable (`ACPMUX_SESSION_ID` can be forged).
    - **Forks:** every fork of a tainted session is refused (simpler than copying the taint and the
      spec in one step).
    - **Export and import (P2-b):** the taint is part of `SessionMeta`, so `MUX_EXPORT`/`MUX_IMPORT`
      (`hub/transfer.rs`, `native::restore`) keep it; until that ships, `MUX_EXPORT` of a tainted
      session is refused.
    - **OS boundary first (rev 14 P1; DECISION D-R pending with the coordinator).** Claude Code
      2.1.289 starts its Bash shell with `detached: true` (`setsid()`), so every Bash command runs in
      a new session and process group, and a peer check on the group alone fails on the default
      path. The primary control is therefore an inherited sandbox. **Coverage:** the sandbox covers
      only Bash and its children; the Claude process itself (Read, Edit, Write, WebFetch,
      WebSearch), stdio MCP servers and hooks run outside it, so the rest of this section still
      guards those. Exact inline keys (facts from the rev 14 review, to be confirmed by the rule 5
      probe on 2.1.289):
      - `sandbox.enabled: true`, `sandbox.autoAllowBashIfSandboxed: false` (its default is true,
        which would let sandboxed Bash skip the permission step), `sandbox.allowUnsandboxedCommands:
        false`, `sandbox.excludedCommands: []`;
      - `sandbox.network.allowUnixSockets: []`, `sandbox.network.allowAllUnixSockets: false`,
        `sandbox.network.allowLocalBinding: false`, `sandbox.network.allowedDomains: []`; Claude has
        no "deny socket" key and Seatbelt checks a socket connect as network-outbound, so the empty
        allowlists are the control (a file deny on the socket path would do nothing); this also
        blocks loopback and acpmux's WebSocket dashboard port;
      - writes: the sandbox write area is a separate **scratch folder**, not the working folder (the
        read root); no extra `allowWrite`, and an `allowWrite` deny on the read root, so approved
        Bash cannot write `LOG.txt` or `TREE/`;
      - the daemon refuses any Bash `rawInput` with `dangerouslyDisableSandbox: true`, and refuses
        every sandbox network-domain approval in a remote chain (a name such as `localtest.me`
        resolves to 127.0.0.1);
      - the managed-settings check (rule 5) refuses any managed `sandbox.*` key outside a reviewed
        list (managed arrays merge with the inline ones);
      - **fail closed:** if Seatbelt is unavailable, Claude may run Bash unsandboxed with only a
        warning, so at every spawn and respawn the agent host runs a canary inside the sandbox: a
        Unix-socket connect and a loopback connect must fail, or the chain is refused.
    - **Children only through the daemon spawn tool.** A remote chain starts a child only through a
      daemon MCP tool. Its inputs are only the prompt text and a workspace from a reviewed list;
      harness, argv, mode, policy, model, env, tools and a free cwd are refused. The parent comes
      from the authenticated caller (the MCP server's peer credentials mapped to the session), never
      from a parameter. The prompt goes in as a rule 10 `document` block. Each spawn asks the human
      with a presence proof, with a depth limit (proposal 2) and a count limit (proposal 4 per chain).
      The child gets the same clean spec and sandbox keys and is tainted. The `mux agents spawn` CLI
      and raw acpmux connects are not a path for a remote chain (the sandbox blocks them).
    - **No persistence by Edit or Write.** Edit and Write run outside the sandbox, so in a remote
      chain these paths are never approvable: `~/Library/LaunchAgents`, `~/Library/LaunchDaemons`,
      shell rc and profile files (`.zshrc`, `.zprofile`, `.bashrc`, `.bash_profile`, `.profile`),
      `.git/hooks`, `~/.config/cmux/cmux.json` (actions), cron and `at` files, and the acpmux and
      daemon configuration.
    - **Peer check, second layer (rev 13 P2, rev 14).** It cannot see a process that was reparented
      to pid 1 (after `setsid` plus exit, or a double fork): such a process looks local, so those
      cases are covered by the sandbox only. acpmux finds the caller from its peer
      credentials (`LOCAL_PEERPID`) and walks the ppid chain (`sysctl KERN_PROC_PID`, `e_ppid`),
      matching the pgid or the sid of any tainted session (`agent.rs` spawns each with
      `process_group(0)`); the set of tainted groups is kept current across respawns. A lookup
      failure, or a peer pid that already exited, fails closed (refused). For a request from inside
      a tainted chain: a new session is tainted and gets the clean spec (rule 4); a peer-forwarded
      `session/new` (`_meta.acpmux.peer`) is refused; its prompts are remote; `permission_respond`,
      a `_acpmux/tag` of `mux.parent`, and policy, mode or default changes are refused; `spawnAgent`
      and `promptAgent` that name an existing local session are refused.
    - **Parent record (rev 14 P2-1).** acpmux stores `tainted_parent` in `SessionMeta` from the
      taint decision and exposes it in `SessionSummary`; the mux host routes child events only on
      it (never on the `mux.parent` tag, which is refused from a tainted caller), and `spawnAgent`
      keeps the created session when the tag is refused, so no orphan untainted session is left.
    - **Child events never prompt the Chief (rev 13 P1).** Code fact: `mux/host/src/agents.ts`
      `spawnAgent` tags every child `mux.parent = "mux"` (the Chief) whatever session spawned it,
      and `host.ts` `childFinished` and `onPermission` send `childFinishedPrompt` and
      `childPermissionPrompt` as plain text prompts into the local Chief. For a tainted child: the
      mux host records the real spawning session; the child's events go only to its tainted
      parent through the daemon (not through the mux host's own acpmux connection), as rule 10
      `document` blocks, or are dropped and written only to the remote log. They never prompt the
      local Chief.
    - **Global settings through an approved call:** an approved Bash call cannot reach acpmux's
      RPC (the sandbox blocks the socket and loopback); the peer check is the second layer.
    - **Notifications:** `notifyCommand` receives the model-controlled title in `ACPMUX_TEXT`; it
      is passed as data (environment), never through a shell string, and the notify command must
      not interpret it.
12c. **No grouped or chat answers (P1, rev 11).** Code facts: `server/requests.rs` sends
    `MUX_PERMISSION_GROUP_RESPOND` to `hub/permission_groups.rs`, which answers every pending item
    with `allow_once` from any client, and its `allow_chat` choice sets `state.chat_allowed`, after
    which `hub/permissions.rs` `handle_permission` answers later read, edit, execute and fetch
    requests itself. For a tainted session: `MUX_PERMISSION_GROUP_RESPOND` (every choice) and
    `allow_chat` are refused from every client; `chat_allowed` stays false; `handle_permission`
    skips `rules::decide`, `policy_for` and `chat_option` and sends each request to the daemon.
    `allow_always` is not offered (`inbound.rs`). `ExitPlanMode`'s `updatedPermissions` (`setMode`)
    is never forwarded.
12d. **Respawn, failover, warm and rehydrate (P1, P2-a; rev 12).** Code facts: `hub/lifecycle.rs`
    `child_for` builds each respawn from the current global harness profile and the
    `MUX_DEFAULTS`/`MUX_PRESETS` environment (any client can change these) and `replay_config`
    re-applies the saved mode; `hub/turns.rs` `run_prompt` fails over on a limit error or "agent
    process closed" by switching `meta.harness` to `fallback_profile` (`claude-sr`); `MUX_WARM`
    (`hub/warm.rs`) calls `child_for` for recent sessions; a failed exact resume sets `rehydrate`,
    and `turns.rs` puts the log transcript in front of the next prompt as plain text. For a tainted
    session:
    - the **clean spawn spec** (rule 4) is stored durably with the taint and fixes the
      permission mode (`default`), the effort and the model at spawn (`spawn_plan` would read them
      from `meta.modes` and the config); `child_for` uses only that
      spec and re-runs the spawn checks (pinned version, `system/init` tool table, managed
      settings); `MUX_DEFAULTS`, `MUX_PRESETS` and `MUX_RELOAD_CONFIG` do not apply;
      `replay_config` forces mode `default`;
    - **no failover**: a limit error ends the turn with an error; a model route change goes only in
      the process environment of the next spawn;
    - `MUX_WARM` skips tainted sessions;
    - **no rehydrate**: a failed resume cancels the chain, and the next chain starts fresh from the
      remote projection. acpmux refuses a fork or handoff of a tainted session
    into a local one (the copy of policy, argv, modes and transcript in `hub/turns.rs` `fork()`
    would make a local approve-all session with a remote transcript). "Absent `_meta.origin` means
    remote" applies to tainted sessions and their descendants; local sessions keep their own
    origin.
13. **Revocation** (section 10) cancels the chain, its child sessions, its open approvals, its
    process group and its queued outbox.

Tests for this section (the acpmux owner adds fake-model probes on a Testbox):
- a remote chain in the Chief's conversation does not resume the local transcript and does not
  inherit its harness, argv, policy, modes or config options.
- a skill with `allowed-tools: Bash`, a custom command with a `!` line, an agent with
  `permissionMode: bypassPermissions` and a plugin hook do not run anything without the daemon;
  `Skill` and `SlashCommand` are denied.
- `--settings` and `--mcp-config` are inline; only the daemon's MCP servers appear; no plugin is
  enabled; an approval for a write to acpmux or daemon configuration is refused.
- remote text that contains a fake closing delimiter, a fake `[mux-event]` line, or `@/etc/hosts`
  in mid-text stays data.
- `_meta.origin` set on any path other than the daemon-only socket is stripped.
- deny paths hold: a Read of `state/x` and of a `*.token` file is denied, `Skill` is denied, and a
  Read inside the read root still reaches the daemon.
- revoke, re-pair, and the next chain starts fresh (no earlier remote-chain session is resumed).
- the spawn argv contains no value from the secrets list.
- an answer from a WebSocket, peer or CLI client for a tainted session is refused; `allow_always`
  is refused; an `updatedInput` that differs from the shown input is refused; an answer without
  the daemon approval id is refused.
- a fork of a remote-chain session, prompted locally, is refused or still asks the daemon; an
  agent-host adopt keeps the taint across a daemon restart; a handoff of a tainted
  session into a local one is refused; a local session without `_meta.origin` keeps local origin.
- a read of a raw conversation file asks; the read root holds only projections (no `work.preview`,
  no `acp_session`, no other cursors, no non-owned conversation).
- a `WebFetch` of `http://127.0.0.1:<port>` asks the human.
- `session/set_model` is refused; a non-Chief agent's read of `.npmrc` asks.
- no env value appears in a remote hook command (the existing no-env-in-JSON test covers the
  inline settings; this one covers hook commands).
- `MUX_PERMISSION_GROUP_RESPOND` (any choice) for a tainted session is refused; `allow_chat` is
  refused; after a refused `allow_chat`, Bash still asks the daemon.
- the daemon's ACP `document` block becomes exactly the Claude JSON above; an unknown block type in
  a tainted session refuses the prompt; a `document` block from a non-daemon client is refused.
- a local prompt into a child session that a remote chain spawned still asks the daemon; a remote
  prompt into an untainted session is refused.
- `allow_always` is not offered on a tainted session; `ExitPlanMode` `updatedPermissions` is never
  forwarded; the approval hash equals sha256 of the forwarded `rawInput` bytes.
- a remote Read of `LOG.txt` (or a file under `TREE/`) asks the human.
- kill the Claude process of a tainted session: the respawn uses the stored inline settings only
  and Bash still asks; a limit error does not fail over; `MUX_WARM` does not spawn a tainted
  session; `MUX_DEFAULTS`/`MUX_PRESETS` values do not reach the respawn; `replay_config` keeps
  mode `default`.
- a failed resume of a tainted session cancels the chain and never rehydrates the transcript.
- `MUX_EXPORT` of a tainted session is refused, or the imported session keeps the taint.
- an untainted `session/new` with a tainted parent is refused.
- a remote chain's child finishes and asks a permission: no prompt arrives in the local Chief
  session; the event reaches the tainted parent as a `document` block or only the remote log.
- a request from a process inside a tainted session's process group: `session/new` is tainted with
  the clean spec, a peer-forwarded `session/new` is refused, `permission_respond`, `mux.parent` tag
  and mode or default changes are refused; a forged `ACPMUX_SESSION_ID` or tag does not taint or
  untaint anything.
- a fork of a tainted session is refused; after `SESSION_DELETE`, adopting its Claude
  `agentSessionId` is still tainted.
- an unknown block type sent through `steer_now` into a tainted session is refused.
- the clean spec fixes mode, effort and model; `meta.modes` values do not reach the spawn.
- through the REAL Bash tool of a remote chain: `mux agents spawn` is refused, a raw connect to the
  acpmux socket or its loopback WebSocket port fails, also after `setsid`, `nohup &` and a double
  fork (the gate-5 probe of rule 5 runs the same cases); `dangerouslyDisableSandbox` is refused.
- a child spawned through the daemon MCP tool is tainted; its finish reaches the parent through the
  daemon; no Chief prompt and no orphan untainted session; `tainted_parent` is in `SessionSummary`.
- from a tainted caller, `spawnAgent` and `promptAgent` that name an existing local session are
  refused; a peer pid that already exited is refused; a failed ppid lookup is refused.
- a plain sandboxed `ls` reaches the daemon (no auto-allow); a Bash call with
  `dangerouslyDisableSandbox: true` is refused; a sandbox domain approval for `localtest.me` is
  refused; the spawn canary refuses the chain when a Unix-socket or loopback connect succeeds.
- approved Bash cannot write in the read root; an Edit of `~/Library/LaunchAgents/x.plist`,
  `.zshrc`, `.git/hooks/pre-commit` or `cmux.json` is refused in a remote chain.
- the daemon spawn tool refuses harness, argv, mode, policy, model, env, tools and a free cwd;
  its parent comes from the caller, not a parameter; the depth and count limits hold.
- the remote projection arrives as the first stdin prompt (not on argv), and an earlier remote
  message with a fake delimiter in it stays inside its block.
- remote text in a `document` block with `</resource>`, a fake `[mux-event]` line, `@/etc/hosts`
  or `/clear` stays data; a bare `/clear` without the prefix would run (so the prefix stays).
- only the closed `--tools` list is offered; an extra tool in `system/init` refuses the chain.
- managed settings with hooks, allow rules or MCP servers refuse the chain at spawn.
- the subrouter route comes from the process environment (`--setting-sources ""` drops the
  settings env).
- path tricks are denied: a symlink in the read root to `state/x`, `.ENV` in upper case,
  `/private/var/...` against `/var/...`, `a/../state/x`; a Bash `grep -r` at the read root asks and
  returns no `state/` content.
- a `system/init` tool list with a tool that is not classified refuses the chain; an MCP call off
  the reviewed list asks the human.
- an approval card for `cat $(echo ... | base64 -d)` shows the substitution and decoding mark.
- `session/set_mode` (`acceptEdits`) and `set_config_option` for a remote-chain session are
  refused from every client, and an Edit still asks the daemon.
- the inline settings and MCP JSON carry no env block, token, key or socket path value.
- the remote-chain process starts in the narrow working folder.
- bypass refused from `--settings` (gate, rule 5); `--dangerously-skip-permissions` refused.
- a user `Bash(*)` allow rule does not skip the daemon; `MUX_POLICY=approve-all`, `--policy`,
  `acpmux session rules`, `/policy` and `/mode` do not change a remote decision; rules changes
  during a remote chain are refused.
- a remote prompt never goes to a pre-existing local session.
- only `allow_once` is offered; no answer, a broken socket and 10 minutes each deny and cancel;
  restart denies pending remote approvals.
- a prompt without `_meta` origin is remote; a client cannot set origin over the web listener or
  the peer path.
- remote `/clear`, `!rm -rf x` and `@/etc/hosts` arrive as text.
- reads of `state/`, a `*.token` file, `.claude/settings.json`, `.env` and the agent token file
  ask approval.
- another harness, an auto-mode agent, `claude-sr` and extra argv are refused for a remote chain.
- revocation kills the chain's process group (a background `sleep` dies).

## 7. Params and content

- `initial_command`, `command`, `tmux_start_command`, `pane_start_command` are refused on every
  method, with no exception.
- Unknown params are refused (no pass-through). New ID-shaped params are denied until scoped.
- `message.send` and `message.edit` accept only `text` parts; `work` parts and approval parts are
  refused by name.
- `runs[].link` is displayed as text and opened only by a user click on the MacBook.

## 8. Outbound filter and redaction (allow-list)

- The remote writer serializes **remote-only structs** (a projection, not the local types with
  fields removed): `RemoteSummary {id, title, participants: [{id, kind, display_name}], last_seq,
  rev, updated_at, last_message}`, `RemoteMessage {id, seq, author, parts (text only), reply_to,
  created_at, edited_at, retracted_at, reactions, origin}`. `acp_session`, `work.session`,
  `work.host`, `work.preview` (it can carry secrets) and `read_cursors` keyed by other participants'
  ids are not in the projection; the peer gets only its own read cursor.
- Events allowed at the writer: `conversation-changed` and `conversation-typing` for owned
  conversations only. Everything else is dropped there, including `pairing-requested` (it carries
  the pairing code, today sent straight to the writer by `subscribe`), terminal output, tree
  events and `ClientChanged` echoes.
- Errors to the remote are codes only, never text with paths or ids. Mapping: `unknown_conversation`,
  `unknown_message`, `not_participant` and every gate refusal -> `remote_denied`; kept as is:
  `actor_mismatch`, `not_author`, `invalid_parts`, `idempotency_conflict`, `cursor_regression`,
  `approval_required`; anything else -> `remote_error`.
- Projections for every event change: `Change::Message` and `Change::MessageUpdated` ->
  `RemoteMessage`; `Change::ReadCursor` -> sent only for the peer's own cursor;
  `Change::Conversation` -> `RemoteSummary`.

## 9. Policy tests (red first, before the feature)

Transport and gate:
- `RemoteRelay.is_unix()` is false, and url-open, loopback-open and a resource-protocol frame
  from a remote connection are refused before their routers.
- a stream without a stamp; a stamp on the admin socket; a stamp from a process that fails the
  peer check (wrong uid or signature); stamp fields inside a frame are ignored.
- an absent principal on the remote entry is refused (no `LOCAL_USER` default).
- table test over every daemon command: only section 4 commands pass; `conversation-search`,
  `conversation-tabs`, `new-conversation-tab`, `conversation-agent-token`, `conversation-bind`
  are refused.
- `set-client-info` with `capabilities: ["loopback-forward"]` is refused; `user_id`,
  `display_name`, `device_*` are ignored (the principal stays the stamp).
- `subscribe` with `surface` or `tree_events` is refused; a pending pairing request is never
  written to a remote connection.

Ownership and mapping:
- pairing adds `remote_<install>` to the owner's conversations; owner peer: `message.send` into a
  `user_local + agent_mux + remote_<install>` conversation succeeds; the stored author is
  `remote_<install>` and the message has `origin.kind == "remote"`; `actor: "user_local"` in a
  remote request gives `actor_mismatch`.
- `message.edit` or `message.retract` of a `user_local`, agent or other-device message:
  `not_author`.
- non-owner peer: list is empty, snapshot of an owner conversation gives `remote_denied`.
- unknown and unowned ids give byte-identical errors.
- each command-bearing param on every allowed method, a `work` part and an approval part are
  refused.

Redaction:
- a serialization test: the remote JSON of a summary, a message and each event contains only the
  section 8 fields (allow-list check, so a new local field cannot leak).

Participants (section 5):
- after pairing, the Chief's wake behavior on a plain local message is unchanged (person count);
- pairing into a conversation at its person budget fails and is reported;
- `participants.add_system` and `participants.remove_system` from a remote peer, a local client or
  an agent: refused; after remove, the device's old messages keep their author and no op is
  accepted as that participant.
- `Change::ReadCursor` of another participant and `Change::Conversation` are projected (or
  dropped) as section 8 says.

Turns and revocation:
- a remote-origin turn asks approval for a write tool and for an outside read; the origin reaches
  a child session and a `[mux-event]` follow-up; it ends at a local human message; an approval
  without a presence proof is not accepted; an unanswered approval after 10 minutes denies and
  cancels the turn; memory-file and scheduled-automation changes ask approval.
- a prompt with one remote and one local message is fully remote; a local message during a running
  remote chain does not clear its mark; a bypass-mode child of a remote chain still asks.
- no setting, `CLAUDE.md`, hook config or permission mode lowers the minimum; an unclassified tool
  asks; a daemon error or timeout denies.
- revocation recheck with an injected clock: 24 hours -> new streams refused, 72 hours -> existing
  closed, unreachable cloud before that closes nothing.
- revocation cancels the turn, its children, its open approvals and its outbox, and closes the
  stream; also while the server is offline from the cloud (section 10).

## 10. Revocation

- A revoke from the cloud (`host.revoke`, `install.revoke_by_team`) reaches the server through its
  cloud connection; in one step the server deletes the pairing record of that install, runs
  `participants.remove_system` for its `remote_<install>`, closes its streams and cancels its
  remote-origin chains (section 6, rule 7).
- Offline from the cloud (D-D, decided): the link rechecks each paired install with
  the control plane every 5 minutes and on each new stream. An unreachable cloud is not a revoke:
  - last good check older than **24 hours**: new streams from that install are refused, existing
    streams stay;
  - last good check older than **72 hours**: existing streams are closed too;
  - a check that says "revoked": everything at once, as above.
  Tests use an injected clock.
- Accepted risk (D-D): a server that stays offline from the cloud keeps serving an install that
  was revoked during the outage for up to 24 hours (new streams) and 72 hours (existing streams).
  The owner can stop it sooner on the server itself (`cmux server unpair`, or Stop Serving).

## 11. Open items

1. Lane 12: `cmux link` does not exist yet. Proposed contract (lane 12 v4): link socket 0600 with
   uid and code-signature checks; `link.dial {host: install_id, service: "daemon"}` returns a
   daemon-protocol stream and `host.watch` path events; first slice direct path only, pairing
   record peers, no relay. Coordinator decision pending.
2. The pairing record on the server: `cmux server pair` (branch feat-cmux-next-server-pair)
   stores `{host, team, user, install}`; the gate reads `user` as the owner.
3. The MacBook side: the `paired` `MachineRegistry` kind runs the existing `ConversationMirror`
   against the link stream with no local-admin assumptions.
4. Attachments (future): a fetch is scoped to an owned message's attachment, never by path.
