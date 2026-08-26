# Agent hook integrations

cmux uses agent hooks to show running state, Feed approvals, notifications, and to restore agent sessions after a normal app relaunch.

Claude Code is handled by the cmux Claude wrapper when Claude Code integration is enabled in Settings. Other agents are installed with:

```bash
cmux hooks setup
cmux hooks setup <agent>
cmux hooks setup --agent <agent>
cmux hooks uninstall <agent>
```

Supported agent names are `codex`, `grok`, `opencode`, `pi`, `omp`, `campfire`, `amp`, `cursor`, `gemini`, `kimi`, `kiro`, `rovodev` (or `rovo`), `copilot`, `codebuddy`, `factory`, and `qoder`. `cmux hooks setup` skips agents whose binary is not on `PATH` and prints a summary.

## Integrations

| Agent | Binary checked | Installed file | Session restore | Feed bridge |
| --- | --- | --- | --- | --- |
| Claude Code | `claude` through wrapper | wrapper-injected settings | `claude --resume <id>` | PermissionRequest |
| Codex | `codex` | `~/.codex/hooks.json`, `~/.codex/config.toml` | `codex resume <id>` | PreToolUse, PermissionRequest telemetry |
| Grok | `grok` | `~/.grok/hooks/cmux-session.json` | `grok -r <id>` | PreToolUse |
| OpenCode | `opencode` | `~/.config/opencode/plugins/cmux-session.js`, `~/.config/opencode/plugins/cmux-feed.js` | `opencode --session <id>` | plugin event bus |
| Pi | `pi` | `~/.pi/agent/extensions/cmux-session.ts` | `pi --session <id>` | tool_execution_start / tool_execution_end telemetry |
| OMP | `omp` | `~/.omp/agent/extensions/cmux-omp-session.ts` or `$PI_CODING_AGENT_DIR/extensions/cmux-omp-session.ts` | `omp --session <id>` | none |
| Campfire | `campfire` | `~/.campfire/agent/extensions/cmux-campfire-session.ts` or `$CAMPFIRE_CODING_AGENT_DIR/extensions/cmux-campfire-session.ts` | `campfire --session <id>` | none |
| Amp | `amp` | `~/.config/amp/plugins/cmux-session.ts` | `amp threads continue <id>` | none |
| Cursor CLI | `cursor-agent` | `~/.cursor/hooks.json` | `cursor-agent --resume <id>` | beforeShellExecution |
| Gemini | `gemini` | `~/.gemini/settings.json` | `gemini --resume <id>` | PreToolUse |
| Kiro CLI | `kiro-cli` | `~/.kiro/agents/cmux.json` or `$KIRO_HOME/agents/cmux.json` | `kiro-cli chat --resume-id <id>` | preToolUse, postToolUse |
| Rovo Dev | `acli` | `~/.rovodev/config.yml` | `acli rovodev run --restore <id>` | none |
| Copilot | `copilot` | `~/.copilot/config.json` | `copilot --resume <id>` | PreToolUse |
| CodeBuddy | `codebuddy` | `~/.codebuddy/settings.json` | `codebuddy --resume <id>` | PreToolUse |
| Factory | `droid` | `~/.factory/settings.json` | `droid --resume <id>` | PreToolUse |
| Qoder | `qodercli` | `~/.qoder/settings.json` | `qodercli --resume <id>` | PreToolUse |
| Kimi Code | `kimi` | `~/.kimi-code/config.toml` or `~/.kimi/config.toml` | not yet | PreToolUse, PostToolUse |

OpenCode also supports project-local Feed installation:

```bash
cmux hooks opencode install --project
```

That writes `.opencode/plugins/cmux-feed.js` in the current directory.

## What the hooks record

Session hooks write `~/.cmuxterm/<agent>-hook-sessions.json`. Each entry stores the agent session ID, cmux workspace ID, surface ID, cwd, process ID when available, current lifecycle (`running`, `idle`, `needsInput`, or `unknown`), and a sanitized launch command. On app relaunch, cmux rebuilds each workspace and runs the agent's native resume command with the saved session ID.

The sanitizer preserves model, sandbox, config, and cwd-related flags. It drops prompts, credentials, old session selectors, and noninteractive commands so relaunch resumes the session instead of starting a new task or leaking secrets.

Each lifecycle mutation also publishes the semantic
`agent.state.changed` event described in [events.md](events.md). Unlike raw
`agent.hook.*` events, its state vocabulary is the same for every integration:
`unknown`, `running`, `idle`, `needs-input`, or `exit`. The payload includes
the agent key, session id when available, prior state, and a process-local
occupant revision. A surface ID used only as a hook-routing fallback is not
published as an agent session ID. For agents that do not report a session ID,
each genuine session-start rotates the occupant revision, while later state
updates remain bound to that revision by an internal process binding that is
not included in event payloads.

Use `cmux wait --surface <id|ref|index> --until
<idle|needs-input|exit> [--timeout <ms>]` to block on that lifecycle. The
server resolves and pins the occupant identity—its reported session ID when
available, otherwise its occupant revision—when the wait starts. A replacement
agent cannot satisfy the wait in either case.

Claude Code's `PushNotification` tool (model-initiated "notify the user now" pushes) is bridged through a `PostToolUse` hook into cmux notifications. The tool normally delivers via a raw OSC desktop notification, which cmux suppresses on surfaces running a hook-integrated agent, so the bridge is what makes those pushes visible inside cmux. It mirrors the tool's own outcome: a push the tool reports as skipped (user active, channel disabled) is not duplicated.

Grok uses its `Notification` hook for user-facing completion messages. cmux records `Stop` as idle state, but leaves the visible notification text to the `Notification` payload so repeated turns keep Grok's own message instead of a generic completion fallback.

## Workspace auto-naming

When the opt-in `automation.workspaceAutoNaming` setting is enabled, turn-end hooks also drive AI naming of workspaces and tabs. Supported adapters are Claude Code, Codex, Grok, OpenCode, Pi, and OMP; each adapter gates on the live setting over the socket, reuses the session store above for throttle state, summarizes with that agent's own CLI in a no-tools or isolated headless mode, and never overwrites a name the user set. Gemini, Amp, Cursor, Antigravity, Kiro, Rovo Dev, Hermes Agent, Copilot, CodeBuddy, Factory, and Qoder are skipped until they have both a verified conversation source and a safe cheap non-interactive summarizer runner. See [workspace-auto-naming.md](workspace-auto-naming.md).

## Agent Hibernation

Agent Hibernation kills idle background agent processes to free their RAM and CPU, then resumes each one with its saved session when you return to its tab. Routine hibernation based on the live-terminal limit is opt-in and off by default. A separate bounded safety path remains active for critical system memory pressure. cmux knows which process belongs to which terminal because the agent hooks associate each session ID with its surface (see the session-restore section above), so it can terminate the right process and bring back the right session.

### When a terminal hibernates

For routine hibernation, a live terminal is only a candidate when all of these hold:

- it has a saved restorable agent session, and the saved launch data can build a resume command
- the agent lifecycle is `idle` (not running, not waiting on input)
- the terminal is in the background (its panel is not currently visible)
- you have more live restorable agent terminals than the live-terminal limit (`maxLiveTerminals`, default `12`)
- the terminal has had no output, input, or lifecycle change for at least the idle window (`idleSeconds`, default `5`)

The live-terminal limit is the first gate. Under the limit, nothing hibernates no matter how long it sits idle. Once you are over the limit, cmux frees only the oldest-idle background terminals, just enough to get back under the limit. Visible terminals are never touched.

Before killing, cmux watches the terminal tail. It samples the last lines of output and a fingerprint of the process, and waits a short confirmation window (`confirmationSeconds`, ~60s) during which the output and process must stay unchanged. Any new output, input, lifecycle change, or PID change cancels the pending hibernation. This is why a small `idleSeconds` is safe: a freshly idle agent that resumes work on its own is never killed mid-task.

So with the defaults, routine hibernation only affects power users running more than 12 agents at once, and even then only ~1 minute after an agent has gone quiet off-screen.

### Critical memory pressure

When macOS reports critical memory pressure, cmux can run the same protected teardown path independently of the `enabled` setting and live-terminal limit. Each pass selects at most two of the oldest eligible background agents. The agent must still be restorable, off-screen, explicitly idle, free of unconfirmed input, stable through the confirmation window, and backed by a transcript cmux can protect. Visible, running, needs-input, recently changed, or unprotectable agents are never selected. Before signaling anything, cmux revalidates the exact process generation and workspace/surface scope.

### What gets killed and how it comes back

cmux sends `SIGTERM` to the agent's process group (scoped to that workspace and surface), then swaps the live terminal for a lightweight placeholder, releasing the terminal's memory and CPU. When you visit the tab again, cmux runs the agent's native resume command with the saved session ID, so the session continues where it left off. The placeholder also shows a Resume button as a manual fallback.

### Enable and configure

Enable routine hibernation from the command palette (`⌘⇧P` -> **Enable Agent Hibernation**), from **Settings > Terminal > Agent Hibernation**, or from the CLI:

```bash
cmux agent-hibernation on
cmux agent-hibernation off
```

Tune the idle window and live-terminal limit from Settings, or set them in `~/.config/cmux/cmux.json`:

```json
{
  "terminal": {
    "agentHibernation": {
      "enabled": true,
      "idleSeconds": 5,
      "maxLiveTerminals": 12
    }
  }
}
```

- `idleSeconds` (default `5`, range `5`-`604800`): how long a background idle agent terminal must be quiet before it can hibernate. Raise it to keep agents alive longer; lower it to reclaim resources sooner. The `confirmationSeconds` settle window still applies on top of this.
- `maxLiveTerminals` (default `12`, range `1`-`256`): how many live restorable agent terminals to keep before cmux hibernates the oldest idle background ones. Lower it to hibernate more aggressively; raise it to keep more agents live.

## Custom surface resume commands

Use `cmux surface resume set --shell <command>` to attach a resume command to the current terminal surface. Public CLI and socket-created commands are kept for inspection and manual restore by default. To auto-run one on restore, approve the prompt or change its signed command prefix in **Settings > Terminal > Resume Commands**.

Approvals are prefix-based and signed by cmux. They also bind the working directory and exact environment values when present. A process can propose a command, but it cannot make that command sticky without the user choosing Auto-Restore or Ask Each Time in cmux.

## Disable automatic resume

To restore panes without automatically restarting saved agent sessions, turn off
**Settings > Terminal > Resume Agent Sessions on Reopen**.

You can also set the same preference in `~/.config/cmux/cmux.json`:

```json
{
  "terminal": {
    "autoResumeAgentSessions": false
  }
}
```

When this is off, cmux still restores the saved window, workspace, pane, scrollback,
and browser state. Restored agent terminals stay idle until you resume them manually.

## Environment overrides

| Agent | Config directory override | Disable cmux hooks for one process |
| --- | --- | --- |
| Codex | `CODEX_HOME` | `CMUX_CODEX_HOOKS_DISABLED=1` |
| Grok | `GROK_HOME` | `CMUX_GROK_HOOKS_DISABLED=1` |
| OpenCode | `OPENCODE_CONFIG_DIR` | `CMUX_OPENCODE_HOOKS_DISABLED=1` |
| Pi | `PI_CODING_AGENT_DIR` | `CMUX_PI_HOOKS_DISABLED=1` |
| OMP | `PI_CODING_AGENT_DIR` for the full agent directory; otherwise `PI_CONFIG_DIR` for the config root | `CMUX_OMP_HOOKS_DISABLED=1` |
| Campfire | `CAMPFIRE_CODING_AGENT_DIR` | `CMUX_CAMPFIRE_HOOKS_DISABLED=1` |
| Amp | none | `CMUX_AMP_HOOKS_DISABLED=1` |
| Cursor CLI | none | `CMUX_CURSOR_HOOKS_DISABLED=1` |
| Gemini | none | `CMUX_GEMINI_HOOKS_DISABLED=1` |
| Kiro CLI | `KIRO_HOME` | `CMUX_KIRO_HOOKS_DISABLED=1` |
| Kimi Code | `KIMI_CODE_HOME`, `KIMI_SHARE_DIR` | `CMUX_KIMI_HOOKS_DISABLED=1` |
| Rovo Dev | none | `CMUX_ROVODEV_HOOKS_DISABLED=1` |
| Copilot | `COPILOT_HOME` | `CMUX_COPILOT_HOOKS_DISABLED=1` |
| CodeBuddy | `CODEBUDDY_CONFIG_DIR` | `CMUX_CODEBUDDY_HOOKS_DISABLED=1` |
| Factory | none | `CMUX_FACTORY_HOOKS_DISABLED=1` |
| Qoder | `QODER_CONFIG_DIR` | `CMUX_QODER_HOOKS_DISABLED=1` |

Pi uses Pi's extension system, not the legacy Pi hooks API. The installed extension is auto-discovered from `~/.pi/agent/extensions/` or `$PI_CODING_AGENT_DIR/extensions/`.

OMP uses OMP's native extension system. OMP native extension discovery scans `${PI_CODING_AGENT_DIR:-~/${PI_CONFIG_DIR:-.omp}/agent}/extensions/`, so cmux installs OMP's extension with a distinct `cmux-omp-session.ts` filename and does not reuse Pi's `cmux-session.ts`.

Campfire ships this integration natively: current campfire versions include a built-in cmux bridge, so no install step is needed (like Claude Code via the cmux wrapper) — `cmux hooks campfire install` exists for older campfire versions, and the installed extension defers to the native bridge when both are present. Campfire embeds vanilla Pi under a `.campfire` white-label, so its extension discovery scans `${CAMPFIRE_CODING_AGENT_DIR:-~/.campfire/agent}/extensions/`. The cmux extension records only the HOST role (`CAMPFIRE_SESSION_ROLE=host`); a joiner is an ephemeral view whose argv carries the invite URL — a capability token that is never persisted or replayed. The extension also subscribes to campfire's in-process observer bridge and surfaces driver-actionable collaborative moments (a joiner waiting in the lobby, a capability ask) as cmux notifications.

Kiro stores hooks inside agent configuration files. The cmux installer creates or updates a `cmux` agent config with lifecycle, tool, and completion hooks; merge the generated `hooks` block into another Kiro agent config if you want the same cmux notifications on that agent.

Kiro Feed verbosity follows **Settings > Automation > Kiro Notification Level** or `automation.kiroNotificationLevel` in `cmux.json`. `minimal` keeps actionable approval cards only, `standard` also keeps mutating tool events, and `verbose` keeps every Kiro tool event.

Kimi ships under two config layouts: Kimi Code CLI reads `${KIMI_CODE_HOME:-~/.kimi-code}/config.toml`, and Kimi CLI 1.49 and earlier read `${KIMI_SHARE_DIR:-~/.kimi}/config.toml`. cmux installs into the file the installed binary reports through `kimi doctor`; when the binary cannot answer, it installs into the first of those two locations that already exists, defaulting to the Kimi Code CLI path. The other location is never emptied by setup: an existing cmux block there is refreshed in place so a second Kimi install keeps working, and a config without a cmux block is left untouched. `cmux hooks uninstall kimi` removes the block from both. Unrelated TOML and third-party hooks are preserved everywhere.

## Troubleshooting

Run `cmux hooks <agent> install --yes` to reinstall one integration. Run `cmux hooks <agent> uninstall --yes` before editing generated files by hand.

If Feed shows nothing, confirm the terminal has `CMUX_SURFACE_ID` and the hook file contains a `cmux hooks feed --source <agent>` command, generated extension bridge, or OpenCode feed plugin. Pi reports non-blocking tool execution telemetry through its generated extension. OMP, Campfire, and Rovo Dev currently provide lifecycle and restore hooks only, so they do not create Feed approval cards. Amp's bundled plugin reports live tab-status updates (idle / thinking / running / reading / done / error / interrupted) and lifecycle restore but does not create Feed approval cards.

If relaunch does not resume an agent, first run `cmux sessions --agent <name> --json` to inspect the saved session without a running cmux socket. If needed, check `~/.cmuxterm/<agent>-hook-sessions.json` and verify the agent's resume command still works outside cmux.
