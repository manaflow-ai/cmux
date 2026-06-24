# Surfacing Claude/Agent Status in the Left Sidebar for Remote SSH-tmux (and `cmux ssh`) Sessions

> Investigation doc. The agent runs on a **remote** host; the local Mac must render its status in the left workspace sidebar. All `file:line` citations verified against the working tree on `main`.

---

## 1. Problem & why it's hard

The existing local agent-status pipeline rests on three assumptions, **all of which fail for a remote agent**:

1. **The visible sidebar indicator is driven by runtime `SidebarStatusEntry` + `agentPIDs` keyed off a real LOCAL OS process — not by any index.** The independent verification *refuted* the idea that `SharedLiveAgentIndex` / `RestorableAgentSessionIndex` drives the sidebar. Those structures feed only the Fork Conversation menu, OpenDiff baseline, and session restore. The actual indicator comes from `tab.statusEntries[...]` populated by live hook reporting, and `Workspace.agentPIDs` (`Sources/Workspace.swift:2491-2495`) is documented as: *"PIDs associated with agent status entries… Used for stale-session detection: if the PID is dead, the status entry is cleared."* So the current path is **structurally PID-gated**.

2. **The local BSD process scan can never see a remote agent.** `allBSDProcesses()` (`Sources/CmuxTopProcessEnumeration.swift:7-8`) enumerates only the local kernel proc table. Scope attribution is by reading each *local* process's own `KERN_PROCARGS2` env for `CMUX_WORKSPACE_ID`/`CMUX_SURFACE_ID` (`Sources/CmuxTopSnapshotScopeCache.swift:191-199`). A Claude running on the SSH host is absent from this table; for `ssh-tmux` there isn't even a local ssh PTY (the mirror reaches the host over plain pipes — `Sources/RemoteTmuxAttachOutcome.swift:6`).

3. **The hook-store live index only counts processes verified live locally.** Even if a synthetic hook record is written to `~/.cmuxterm/<kind>-hook-sessions.json`, `RestorableAgentSessionIndex.load()` drops any record that declares a `pid` but has no matching live local process (`Sources/RestorableAgentSession.swift:1166-1168`), and `liveScopedProcessID` (`:1761-1795`) requires a live process whose env matches `matchesCMUXScope` + `CMUX_AGENT_LAUNCH_KIND` + executable basename. `SharedLiveAgentIndex` loads with `detectedSnapshots:[:]` (`Sources/Workspace.swift:2029`), so the process-detected path doesn't even feed it. `hasLiveProcess` (`:1014-1016`) is `!processIDs.isEmpty`, and `processIDs` only becomes non-empty via a verified local PID.

**Conclusion:** there is no ready-made "inject a record → sidebar lights up" seam that bypasses local PID verification. A remote design must write into the **runtime status surface** (`SidebarStatusEntry` / `progress` / `latestConversationMessage`) — *not* the restorable index — and must carry a non-PID liveness signal.

The two transport modes also differ sharply in baseline capability:

| Mode | Local PTY for agent? | Inherited `CMUX_WORKSPACE_ID/SURFACE_ID` on remote? | Relay RPC channel back to Mac? |
|---|---|---|---|
| `cmux ssh` (non-tmux) | Yes — real local ssh PTY in a Ghostty surface (`CLI/cmux.swift:8703-8788`) | Yes — sed placeholder substitution into remote login shell (`CLI/cmux.swift:9357-9359`) | Yes — `CMUX_SOCKET_PATH=127.0.0.1:<relayPort>` reverse forward |
| `ssh-tmux` (mirror) | **No** — plain pipes, no per-session PTY (`Sources/RemoteTmuxAttachOutcome.swift:6`) | **No** — `runRemoteTmux` carries no cmuxd/relay bootstrap (`CLI/cmux.swift:8423-8432`) | **No** — must be built from scratch |

So `cmux ssh` is *highly* feasible (it already has both env propagation and a relay channel). `ssh-tmux` is the hard case and the focus of approaches (a)/(b) below, which ride the tmux control connection instead of a relay.

---

## 2. The render path & injection point

The sidebar row (`TabItemView`, `Sources/ContentView.swift:12909-12942`) is `Equatable` and renders a `SidebarWorkspaceSnapshotBuilder.Snapshot` assembled in `makeWorkspaceSnapshot()` (`Sources/ContentView.swift:14466-14482`). The agent-status fields of that snapshot are:

- `metadataEntries: [SidebarStatusEntry]` → rendered as `SidebarMetadataRows` (`Sources/ContentView.swift:13484-13498`)
- `progress: SidebarProgressState?` → rendered as a Capsule progress bar (`Sources/ContentView.swift:13527-13539`)
- `latestConversationMessage` / `latestLog` → latest-message row (`Sources/ContentView.swift:13513-13525`)

These map back to `Workspace` properties that forward to `WorkspaceSidebarMetadataModel` via computed get/set (`Sources/Workspace.swift:2386-2403`). The model is the observed source of truth:

- `WorkspaceSidebarMetadataModel.statusEntries: [String: SidebarStatusEntry]` (`Packages/macOS/CmuxSidebar/.../WorkspaceSidebarMetadataModel.swift:30`, backed by `statusEntriesSubject` CurrentValueSubject at `:80`)
- `WorkspaceSidebarMetadataModel.progress: SidebarProgressState?` (`:48`, subject at `:86`)
- Helpers: `addStatusEntry(_:)` (`:164`), `updateProgress(_:)` (`:193`), `invalidateWorkspaceObservation()` (`:157`)

Observation fuses through `Workspace.makeSidebarObservationPublisher` (CombineLatest over `statusEntriesPublisher`/`progressPublisher`) plus `$latestConversationMessage` etc., `removeDuplicates()` (`Sources/WorkspaceSidebarObservation.swift:14-140`).

### The exact injection point — already proven by the control socket

The control socket **already injects status this exact way** (verified):

```
Sources/TerminalController+ControlSidebarContext.swift:37   current: tab.statusEntries[key],
Sources/TerminalController+ControlSidebarContext.swift:52   tab.statusEntries[key] = SidebarStatusEntry(...)
Sources/TerminalController+ControlSidebarContext.swift:301  tab.progress = SidebarProgressState(value: value, label: label)
Sources/TerminalController+ControlSidebarContext.swift:309  tab.progress = nil
```

This is the proof that an **external source can drive the indicator with zero UI changes**. A remote mirror should write the same way:

- **Coarse activity / model chip:** `workspace.statusEntries["agent.remote"] = SidebarStatusEntry(key:value:icon:color:url:priority:format:timestamp:)` (i.e. `WorkspaceSidebarMetadataModel.addStatusEntry` at `:164`).
- **Running spinner / progress:** `workspace.progress = SidebarProgressState(value:label:)` (`updateProgress` at `:193`).
- **Latest message preview:** `Workspace.recordConversationMessage(_:)` (`Sources/Workspace.swift:5256-5271`).

### What a "synthetic record" needs (and what it must NOT be)

A remote status write must mutate one of the **observed runtime properties above** to re-render. It must **NOT** go through `RestorableAgentSessionIndex`/`SharedLiveAgentIndex` — those require a verified local PID and carry no running flag (`RestorableAgentSessionIndex.snapshot` returns only session identity, `Sources/RestorableAgentSession.swift:998-1000`).

Caveats that affect a synthetic entry:
- `shouldReplaceStatusEntry` dedupes before assignment (`Sources/TerminalController+ControlSidebarContext.swift:36-45`) — use a **stable key** and meaningful value/priority/timestamp changes or the row appears stale.
- Rendering is gated by `detailVisibility.showsMetadata` / `showsProgress` (`Sources/ContentView.swift:13484, 13527`) — verify the sidebar detail level when testing.
- Status entries are **intentionally not persisted** across restore (`Sources/Workspace.swift:218`) — the remote mirror is the right owner; values vanish on relaunch unless re-supplied.

---

## 3. Remote signals available today

For `ssh-tmux`, the live tmux control connection (`RemoteTmuxControlConnection`) is the primary signal source; the separate `RemoteTmuxSSHTransport` provides arbitrary one-shot remote exec over the same ControlMaster.

| Signal | How it arrives | file:line | Cadence | Fidelity for agent status |
|---|---|---|---|---|
| `pane_current_command` (foreground comm name) | live sub `refresh-client -B "cmux_reflow_<paneId>:%<paneId>:#{alternate_on}\|#{pane_current_command}"` | `RemoteTmuxControlConnection.swift:737-740`; one-shot `:705-711` | On subscribe + on change (~1s tmux re-eval, `:781-787`) | Coarse — comm name only (e.g. `node`, not `claude`); no PID/argv |
| `alternate_on` | rides with `pane_current_command` | `RemoteTmuxControlConnection.swift:705-711` | With command | Distinguishes full-screen TUI from shell |
| `pane_current_path` (cwd) | live sub `cmux_cwd_<paneId>` | `RemoteTmuxControlConnection.swift:677-679`; one-shot `:664-669` | On change | Gives the cwd → derive Claude project-dir hash |
| Window names + layouts | `list-windows -F "#{window_id} #{window_layout} #{window_name}"` | `RemoteTmuxControlConnection.swift:567-572` | On topology change | Tab title text |
| Raw `%output` bytes | control-mode `%output %<paneId> …` | `RemoteTmuxControlConnection.swift:1141-1144` | Continuous push | Byte counts → activity heuristic |
| Live close-time activity (eval at query time) | `display-message … "#{pane_id}\|#{alternate_on}\|#{pane_current_command}"` | `RemoteTmuxControlConnection.swift:775-778` | On demand | Bypasses ~1s cache staleness |
| **Arbitrary remote exec** (read files, `claude --version`) | `RemoteTmuxSSHTransport.run([...])` over shared ControlMaster, no new auth | `RemoteTmuxSSHTransport.swift:75-87` (confirmed); `runTmux` wrapper `:64-67` | On demand; subsecond on warm master | **High** — can read `~/.claude/sessions/<pid>.json` + transcript |
| Existing foreground projection | `RemoteTmuxController.mirrorTabActivity(...)` → `MirrorTabActivity(hasActiveCommand, activeCommandName)` | `RemoteTmuxController.swift:667-682`; cached states `RemoteTmuxControlConnection.swift:74` | On query | Already wired; today only drives close-confirmation |

**Critical gaps (verified):** there is **no `pane_pid`, no remote PID, and no `pane_tty`** subscribed or queried anywhere in `RemoteTmux*.swift`. `pane_current_command` is the comm name (≤~16 chars) — Claude usually appears as `node`, so comm-name matching alone is unreliable.

`RemoteTmuxSSHTransport.run` returns `RemoteTmuxCommandResult{exitCode, stdout, stderr}` (`RemoteTmuxSSHTransport.swift:257-261`), stdout capped at 1 MiB, each argv token single-quoted (so use `run(["sh","-c","cat ~/.claude/..."])` for tilde/glob expansion).

### What a remote Claude actually exposes under `~/.claude` (read-only over SSH)

- `~/.claude/sessions/<pid>.json` — best signal **when present**: `{pid, sessionId, cwd, version, kind, entrypoint, status:"busy"|"idle", updatedAt/statusUpdatedAt}`. **But `status` is version/entrypoint-dependent** (absent on 2.1.170 conductor sdk-ts and VS Code entrypoint). Do not rely on it alone.
- `~/.claude/projects/<cwd-hash>/<sessionId>.jsonl` — **universal** live signal. Appended in real time; mtime within ~10s on actively-working panes. Cheapest reliable "working" proxy: compare newest jsonl mtime vs `date +%s`.
- Per-line fields parsed by cmux's `extractClaudeMetadata` (`Sources/SessionIndexStore.swift:769-840`): `cwd` (`:777`), `gitBranch` (`:780`), `permissionMode` (`:783`), assistant `message.model` (`:786-790`, strip `[1m]` suffix at `:835-838`), title from first user message (`:791-808`).
- cwd→hash is deterministic (`encodeClaudeProjectDir`, replace `/` and `.` with `-`); hash→cwd is lossy (`decodeClaudeProjectDir`, `Sources/SessionIndexStore.swift:863`), so prefer reading the jsonl `cwd` field for ground truth.

---

## 4. Candidate approaches (ranked)

### Rank 1 — (a) Foreground-command detection → coarse activity chip *(ship first)*

- **Mechanism:** Reuse the *already-flowing* `pane_current_command` + `alternate_on` cached in `RemoteTmuxControlConnection.paneForegroundStates` (`:74`), classified at `classifyAndEmitReflow` (`:718-720`) and projected by `mirrorTabActivity` → `MirrorTabActivity(hasActiveCommand, activeCommandName)` (`RemoteTmuxController.swift:667-682`). Match `activeCommandName` against an agent-executable allowlist (`node`/`claude`/`bun`/`python`/`codex`…). When matched, write `workspace.statusEntries["agent.remote"] = SidebarStatusEntry(...)` and optionally `workspace.progress`.
- **Crosses SSH:** nothing new — signal already arrives on the live control stream.
- **Fidelity:** coarse. "An agent-ish command is foregrounded in this pane." Cannot say *which* agent reliably (comm is `node`), cannot say busy-vs-idle, no model/title.
- **Effort:** **S.** Mostly wiring `mirrorTabActivity` output into a `SidebarStatusEntry` write. No new transport.
- **Invasiveness:** Low. One new status-entry key; reuses the existing render path.
- **Risks:** comm-name ambiguity (`node` ≠ proof of Claude); ~1s cache staleness (use the live activity query `:775-778` for accuracy); allowlist false positives (any `node` REPL lights up); `|` field-separator parsing must respect `maxSplits` if format extended (`RemoteTmuxPaneForegroundState.swift:7`).

### Rank 2 — (b) Remote transcript/session read over the existing ControlMaster *(richest, still no remote install)*

- **Mechanism:** Gate on Rank-1 detecting an agent foregrounded; then `RemoteTmuxSSHTransport.run(["sh","-c", "<script>"])` (`RemoteTmuxSSHTransport.swift:75-87`) to: (1) `stat` newest `~/.claude/projects/<hash>/*.jsonl` mtime vs `date +%s` → busy/idle; (2) `tail -1` the active jsonl → `message.model` + title; (3) optionally `cat ~/.claude/sessions/<pid>.json` for explicit `status` when present. Derive `<hash>` from the pane cwd (already available via `pane_current_path`, `:677-679`) using the `encodeClaudeProjectDir` rule. Map parsed fields into `SidebarStatusEntry` (model/activity chip) + `Workspace.recordConversationMessage` (latest preview) + `progress` (busy spinner).
- **Crosses SSH:** small periodic one-shot reads (a few hundred bytes) over the warm master.
- **Fidelity:** **High** — model name, busy/idle, latest message, title. Reuses `extractClaudeMetadata` parsing logic (`Sources/SessionIndexStore.swift:769-840`).
- **Effort:** **M.** New polling actor + a parser (or lift `extractClaudeMetadata` to operate on remote bytes), plus throttling.
- **Invasiveness:** Medium. Adds periodic remote exec (latency, battery, security surface — reads user files over SSH).
- **Risks:** `status` field non-universal (fall back to mtime); mtime briefly stale during long tool calls / fresh-after-finish (pick ~30s threshold); lossy hash→cwd (use jsonl `cwd`); multiple sessions per cwd → must resolve pane's actual pid→sessionId, which tmux does **not** give (no `pane_pid`); `~/.claude` is 0600/0700, readable only as the owning remote user; `run` is not cancellation-aware and caps stdout at 1 MiB; do not write into `~/.claude`.

### Rank 3 — (c) Remote cmux-hook injection POSTing status back over the relay

- **Mechanism:** Provision the remote `cmux` CLI + reverse relay so the remote Claude's hooks call `cmux --socket "$CMUX_SOCKET_PATH" hooks claude …` against `127.0.0.1:<relayPort>`, landing on the local daemon via `RemoteCLIRelayServer` (auth: HMAC-SHA256 with `relay_id`/`relay_token`, `CLI/cmux.swift:2098-2226`). This is the *real* hook path and yields true SessionStart/Stop/Notification events.
- **Crosses SSH:** loopback-TCP relay (reverse forward `ssh -O forward` / `-N -R`, `RemoteSessionCoordinator+ReverseRelay.swift:13-145`).
- **Fidelity:** **Highest** — authoritative lifecycle events, same as local agents.
- **Effort:** **L**, and **partially blocked for `ssh-tmux`.** The relay/cmuxd bootstrap exists for `cmux ssh` SSH workspaces but **not** for `runRemoteTmux` (`CLI/cmux.swift:8423-8432`) — would need to be built from scratch for the mirror. Even for `cmux ssh`, the **Claude wrapper hard-gates hook injection on a unix-socket `-S` test** (`Resources/bin/cmux-claude-wrapper:62-77, :414-426`); a remote `CMUX_SOCKET_PATH=127.0.0.1:<port>` is a TCP endpoint, so `-S` fails and the wrapper passes through to real `claude` **with no hooks**. Fixing this requires teaching `cmux_socket_available()` to accept a `host:port` relay endpoint (mirror `parseRelayEndpoint`, `CLI/cmux.swift:2079-2096`).
- **Invasiveness:** High. Remote provisioning, wrapper change, relay lifecycle, VM/Freestyle skip-bootstrap edge cases.
- **Risks:** relay-auth provisioning required (`relay_id` + 64-hex `relay_token`); reverse relay gated on daemonReady; hook timeout budget over SSH latency (5s most events / 120s feed); silent `{}` degradation hides failures.

**Ranking rationale:** (a) is days-of-work for a visible win reusing flowing data; (b) adds real fidelity with no remote install, building directly on (a)'s gating + existing `extractClaudeMetadata`; (c) is the "correct" long-term answer but is the largest lift and is structurally blocked for `ssh-tmux` and gated by the wrapper for `cmux ssh`.

---

## 5. Recommended first attempt

**Ship (a) — foreground-command → coarse remote agent chip — then layer (b) behind the same gate.** Smallest change, immediate visible win, reuses the proven `SidebarStatusEntry` render path.

### Concrete edit points

1. **Detect the agent in the existing projection.** `RemoteTmuxController.mirrorTabActivity` (`Sources/RemoteTmuxController.swift:667-682`) already extracts `activeCommandName` from `paneForegroundStates`. Add an agent-allowlist classifier here (or in `RemoteTmuxPaneForegroundState`, alongside `plainShellCommands` at `RemoteTmuxPaneForegroundState.swift:12-16`) that returns whether the foreground command looks like an agent.

2. **Write the runtime status entry on the owning workspace.** Where the mirror updates per-tab activity today (the consumer of `MirrorTabActivity`, `RemoteTmuxController.swift:706/728`), add:
   - `workspace.statusEntries["agent.remote"] = SidebarStatusEntry(key: "agent.remote", value: <agentLabel>, icon: …, priority: …, timestamp: Date())` — mirroring `Sources/TerminalController+ControlSidebarContext.swift:52`.
   - Clear it (`workspace.statusEntries["agent.remote"] = nil`) when `hasActiveCommand` drops, mirroring the `progress = nil` clear at `:309`.

3. **(Optional, same PR) coarse spinner:** `workspace.progress = SidebarProgressState(value: …, label: "Agent")` while active (mirror `:301`).

4. **Localization:** any user-visible chip label must use `String(localized:)` and be added to `Resources/Localizable.xcstrings` for en + ja (per CLAUDE.md localization-audit rule).

Stage (b) afterward behind the same `hasActiveCommand && isAgentCommand` gate: a throttled `RemoteTmuxSSHTransport.run(["sh","-c", …])` reading transcript mtime + `tail -1`, feeding model/title into the same `SidebarStatusEntry` and `Workspace.recordConversationMessage`.

### Test plan

- **Unit:** classifier over `RemoteTmuxPaneForegroundState` values — `node`/`claude`/`bun` → agent; `bash`/`zsh`/`vim` → not (assert against `plainShellCommands`). Wire the test file into `cmux.xcodeproj/project.pbxproj` (4 pbxproj entries) or it silently runs 0 tests (CLAUDE.md pitfall; `scripts/lint-pbxproj-test-wiring.sh`).
- **Unit:** given a `MirrorTabActivity{hasActiveCommand:true, activeCommandName:"node"}`, assert a `SidebarStatusEntry` with the stable key is written and removed when activity drops (respect `shouldReplaceStatusEntry` dedup, `TerminalController+ControlSidebarContext.swift:36-45`).
- **Manual (tagged build, per CLAUDE.md):** `./scripts/reload.sh --tag remote-agent-status --launch`; open an `ssh-tmux` session, run `claude` in a pane, confirm the left-sidebar row shows the chip and clears on exit. Verify the sidebar detail level shows metadata (`showsMetadata`, `ContentView.swift:13484`).
- **Regression two-commit structure** (CLAUDE.md): commit 1 = failing test, commit 2 = the wiring.

---

## 6. Open questions / empirically verify by running

1. **Comm name for interactive Claude:** does `pane_current_command` read `node`, `claude`, or something else for a plain interactive `claude` in tmux on the target host? (Findings show `node` is likely.) Run a real `ssh-tmux` session and read the live reflow subscription value. Determines whether the allowlist needs `node` (high false-positive) or can match `claude` directly.
2. **`alternate_on` behavior for Claude:** does interactive Claude enter the alternate screen (`alternate_on=1`)? If yes, `alternate_on` materially sharpens the heuristic beyond comm name.
3. **`sessions/<pid>.json` status availability on the target host's Claude build** — confirm whether `status` is present for the builds the user actually runs (it was absent on 2.1.170/VS Code). Decides whether (b) needs the mtime fallback as the *primary* signal.
4. **Pane→sessionId attribution without `pane_pid`:** with multiple concurrent sessions in one cwd, can we attribute the right transcript to the right pane? tmux gives no remote PID. Verify whether adding `#{pane_pid}` to the subscription (note: it's the *shell* PID, not the child) plus a remote `pgrep -P` walk can recover the agent PID, or whether we accept cwd-level (not pane-level) granularity in v1.
5. **`run()` latency/throttle budget:** measure round-trip of `RemoteTmuxSSHTransport.run(["sh","-c","stat …"])` over a warm master to pick a poll interval that doesn't churn battery/CPU.
6. **`cmux ssh` (non-tmux) parallel path:** confirm whether approach (b)/(c) is cheaper there given the relay channel already exists (`CMUX_SOCKET_PATH=127.0.0.1:<relayPort>`) — possibly worth a separate, higher-fidelity implementation for that mode reusing `surface.report_tty`-style RPC rather than the tmux signal path.
7. **Wrapper unix-socket gate (for approach c):** confirm exactly where `cmux_socket_available()` rejects a TCP endpoint (`Resources/bin/cmux-claude-wrapper:62-77`) and scope the change to accept `host:port` relay endpoints.

---

**Files most relevant to the prototype (absolute paths):**
- `/Users/maxshmi/Developer/cmux/Sources/RemoteTmuxController.swift` (mirrorTabActivity, lines 667-735)
- `/Users/maxshmi/Developer/cmux/Sources/RemoteTmuxControlConnection.swift` (paneForegroundStates :74, classifyAndEmitReflow :718, subscriptions :677/:737, live activity query :775)
- `/Users/maxshmi/Developer/cmux/Sources/RemoteTmuxPaneForegroundState.swift` (PaneForegroundState, plainShellCommands :12)
- `/Users/maxshmi/Developer/cmux/Sources/RemoteTmuxSSHTransport.swift` (run :75-87, result :257)
- `/Users/maxshmi/Developer/cmux/Sources/TerminalController+ControlSidebarContext.swift` (status-entry write :52, progress :301/:309 — the render-path template)
- `/Users/maxshmi/Developer/cmux/Packages/macOS/CmuxSidebar/Sources/CmuxSidebar/WorkspaceModel/WorkspaceSidebarMetadataModel.swift` (addStatusEntry :164, updateProgress :193, subjects :80/:86)
- `/Users/maxshmi/Developer/cmux/Sources/ContentView.swift` (Snapshot :12909, makeWorkspaceSnapshot :14466, render :13484/:13527)
- `/Users/maxshmi/Developer/cmux/Sources/SessionIndexStore.swift` (extractClaudeMetadata :769-840 — reuse for remote jsonl parsing)
- `/Users/maxshmi/Developer/cmux/Sources/Workspace.swift` (status forwarding :2386-2403, recordConversationMessage :5256-5271, agentPIDs :2491)
---

## 7. Empirical findings (live, against a real AL2023 dev host)

Probed a real `ssh-tmux`-mirrored host running interactive Claude. These resolve
several "open questions" above:

- **`pane_current_command` reads `claude`, not `node`.** `tmux list-panes -a -F
  '#{pane_current_command}'` on the live session reported `claude` for the pane
  running Claude Code (toolbox build 2.1.183). So comm-name matching against the
  agent executable allowlist is **reliable on this host** — the feared `node`
  ambiguity did not occur. (Caveat: other Claude install methods / npm-global may
  still surface as `node`; allowlist stays conservative.)
- **`alternate_on = 0` for interactive Claude** — it does not use the alternate
  screen, so `alternate_on` does not sharpen detection; the comm name is the signal.
- **`~/.claude/sessions/<pid>.json` exists and carries `status`** =
  `idle` | `busy` | `shell`, plus `version`, `cwd`, `sessionId`. Example:
  `{"pid":3122858,"sessionId":"…","cwd":"…/realtime-core","version":"2.1.183","status":"idle",…}`.
  Usable for busy/idle, **but** keyed by an inner pid that is not the tmux
  `pane_pid` (the pane reports the shell pid; Claude is a descendant), so pid→
  session mapping needs a remote child-process walk.
- **cwd → transcript path works without the pid.** From the pane's
  `pane_current_path` alone: `HASH = sed 's#[/.]#-#g'` over the cwd →
  `~/.claude/projects/<HASH>/*.jsonl`; newest file's mtime vs `date +%s` gives a
  busy/idle proxy, and `tail -1 | jq .message.model` gives the model. Verified
  end-to-end over plain ssh (age computed, last line parsed). This is the
  **recommended Attempt-2 signal** — no pid walk required.
- **Arbitrary remote exec over the shared master works** as the verification
  predicted (`RemoteTmuxSSHTransport.run`).

## 8. Attempt log

### Attempt 1 — coarse "agent running" chip (IMPLEMENTED)

Branch `feat-remote-tmux-agent-status`. Reuses the already-streamed
`pane_current_command` (cached in `RemoteTmuxControlConnection.paneForegroundStates`).

- `RemoteTmuxPaneForegroundState.agentProvider` maps a foreground comm name to an
  `AgentSessionProviderID` (`claude`/`codex`/`opencode`).
- `RemoteTmuxSessionMirror.refreshAgentStatus()` scans the session's panes and
  writes a single keyed `SidebarStatusEntry` (`"remote-tmux.agent"`,
  `"<Agent> running"`, `sparkles` icon) to `workspace.statusEntries` — the same
  runtime surface the control socket writes — and clears it when no agent is
  foregrounded or on teardown. Called from the `onPaneReflow` observer (foreground
  change) and `rebuild()` (topology change).
- Unit tests: `agentProvider` classification (agent vs shell/tool/empty).
- Fidelity: presence only (no busy/idle, no model). Effort: S. Zero UI changes.

### Attempt 3 — tmux `@cmux_agent` user-option hook channel (IMPLEMENTED — the clean path)

The recommended Option C, now built and validated live for both Claude and Codex.

- **Remote install (`RemoteTmuxAgentHookInstaller`):** on first attach to a host,
  cmux writes a dependency-free hook into the remote `~/.claude/settings.json`
  (Claude) and `~/.codex/hooks.json` (Codex) over the open ControlMaster
  (`RemoteTmuxController.installRemoteAgentStatusHooks`, once-per-host,
  fire-and-forget, via a python3 JSON merger that preserves the user's other
  hooks and replaces only cmux-marked entries). The hook fires on
  SessionStart→running, UserPromptSubmit→working, Stop→idle; its body is
  `tmux set -t "$TMUX_PANE" @cmux_agent '{"agent":…,"state":…,"model":…}'`,
  self-disabling when not inside tmux and always printing `{}` for blocking-hook
  stdout.
- **Local receive:** cmux subscribes `#{@cmux_agent}` per pane
  (`RemoteTmuxControlConnection.subscribePaneAgent`, alongside `cmux_cwd_`/
  `cmux_reflow_`), parses the value with `RemoteTmuxAgentStatus`, and writes the
  sidebar entry via `RemoteTmuxSessionMirror` — taking precedence over Attempts
  1/2 when a hook is reporting.
- **Verified live (tmux 3.6a):** setting `@cmux_agent` pushes
  `%subscription-changed cmux_agent_<pane> … : <json>`; the generated install
  command merges cleanly into the remote settings; and the installed hook, run as
  Claude invokes it (event JSON on stdin), sets the option to a value the parser
  accepts (model `[1m]` suffix stripped).
- **Fidelity:** authoritative running/working/idle + model, agent-agnostic. No
  remote cmux CLI, no socket, no relay, no auth. Pure builders/parsers
  (`RemoteTmuxAgentStatus`, `RemoteTmuxAgentHookInstaller`) are unit-tested.

### Attempt 2 — remote `~/.claude` read for busy/idle + model (IMPLEMENTED)

Gated on Attempt 1's detection (Claude only). When the agent's pane has a known
cwd (`cmux_cwd_` subscription), a throttled one-shot
`RemoteTmuxSSHTransport.run(["sh","-c", …])` over the shared master:
- `RemoteTmuxAgentProbe.activityProbeCommand(cwd:)` derives the project-dir name
  (same `/`+`.`→`-` rule as `encodeClaudeProjectDir`), finds the newest
  `~/.claude/projects/<dir>/*.jsonl`, prints `now<US>mtime<US>path` (portable
  GNU/BSD `stat`). `parseActivity` → busy iff `(now - mtime) ≤ 30s`.
- `RemoteTmuxAgentProbe.modelProbeCommand(transcriptPath:)` tails the transcript
  for the last `"model":"…"`; `parseModel` strips the `[1m]` suffix.
- The chip upgrades from "Claude Code running" to "Claude Code working · <model>"
  / "Claude Code idle · <model>", with a `sparkles`/`moon.zzz` icon.

`RemoteTmuxAgentProbe` is a pure builder+parser with full unit coverage
(`RemoteTmuxAgentProbeTests`); the async exec + 4s throttle + teardown
cancellation live in `RemoteTmuxSessionMirror.scheduleAgentProbe`. Re-probes on
foreground change, topology change, and cwd arrival. Effort: M.

**Not yet done / follow-ups:** periodic refresh while busy (today it re-probes on
events, not on a timer, so a long tool-call's busy→idle edge can lag until the
next event); codex/opencode enrichment (only Claude reads transcripts);
multi-session-per-cwd disambiguation (uses the newest transcript in the dir).
