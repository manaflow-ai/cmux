# Agent hook integrations

cmux uses agent hooks to show running state, Feed approvals, notifications, and to restore agent sessions after a normal app relaunch.

Claude Code is handled by the cmux Claude wrapper when Claude Code integration is enabled in Settings. Other agents are installed with:

```bash
cmux hooks setup
cmux hooks setup <agent>
cmux hooks setup --agent <agent>
cmux hooks uninstall <agent>
```

Supported agent names are `codex`, `grok`, `opencode`, `pi`, `omp`, `campfire`, `amp`, `cursor`, `gemini`, `kiro`, `rovodev` (or `rovo`), `copilot`, `codebuddy`, `factory`, and `qoder`. `cmux hooks setup` skips agents whose binary is not on `PATH` and prints a summary.

## Integrations

| Agent | Binary checked | Installed file | Session restore | Feed bridge |
| --- | --- | --- | --- | --- |
| Claude Code | `claude` through wrapper | wrapper-injected settings | `claude --resume <id>` | PermissionRequest |
| Codex | `codex` | `~/.codex/hooks.json`, `~/.codex/config.toml` | `codex resume <id>` | PreToolUse, PermissionRequest telemetry |
| Grok | `grok` | `~/.grok/hooks/cmux-session.json` | `grok -r <id>` | PreToolUse |
| OpenCode | `opencode` | `~/.config/opencode/plugins/cmux-session.js`, `~/.config/opencode/plugins/cmux-feed.js` | `opencode --session <id>` | plugin event bus |
| Pi | `pi` | `~/.pi/agent/extensions/cmux-session.ts` | `pi --session <id>` | none |
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

OpenCode also supports project-local Feed installation:

```bash
cmux hooks opencode install --project
```

That writes `.opencode/plugins/cmux-feed.js` in the current directory.

## What the hooks record

Session hooks write `~/.cmuxterm/<agent>-hook-sessions.json`. Each entry stores the agent session ID, cmux workspace ID, surface ID, cwd, process ID when available, current lifecycle (`running`, `idle`, `needsInput`, or `unknown`), and a sanitized launch command. On app relaunch, cmux rebuilds each workspace and runs the agent's native resume command with the saved session ID.

The sanitizer preserves model, sandbox, config, and cwd-related flags. It drops prompts, credentials, old session selectors, and noninteractive commands so relaunch resumes the session instead of starting a new task or leaking secrets.

Grok uses its `Notification` hook for user-facing completion messages. cmux records `Stop` as idle state, but leaves the visible notification text to the `Notification` payload so repeated turns keep Grok's own message instead of a generic completion fallback.

## Workspace auto-naming

When the opt-in `automation.workspaceAutoNaming` setting is enabled, turn-end hooks also drive AI naming of workspaces and tabs. Supported adapters are Claude Code, Codex, Grok, OpenCode, Pi, and OMP; each adapter gates on the live setting over the socket, reuses the session store above for throttle state, summarizes with that agent's own CLI in a no-tools or isolated headless mode, and never overwrites a name the user set. Gemini, Amp, Cursor, Antigravity, Kiro, Rovo Dev, Hermes Agent, Copilot, CodeBuddy, Factory, and Qoder are skipped until they have both a verified conversation source and a safe cheap non-interactive summarizer runner. See [workspace-auto-naming.md](workspace-auto-naming.md).

## Agent Hibernation

Agent Hibernation kills idle background agent processes to free their RAM and CPU, then resumes each one with its saved session when you return to its tab. It is opt-in and off by default. cmux knows which process belongs to which terminal because the agent hooks associate each session ID with its surface (see the session-restore section above), so it can terminate the right process and bring back the right session.

### When a terminal hibernates

A live terminal is only ever a candidate when all of these hold:

- it has a saved restorable agent session, and the saved launch data can build a resume command
- the agent lifecycle is `idle` (not running, not waiting on input)
- the terminal is in the background (its panel is not currently visible)
- you have more live restorable agent terminals than the live-terminal limit (`maxLiveTerminals`, default `12`)
- the terminal has had no output, input, or lifecycle change for at least the idle window (`idleSeconds`, default `5`)

The live-terminal limit is the first gate. Under the limit, nothing hibernates no matter how long it sits idle. Once you are over the limit, cmux frees only the oldest-idle background terminals, just enough to get back under the limit. Visible terminals are never touched.

Before killing, cmux watches the terminal tail. It samples the last lines of output and a fingerprint of the process, and waits a short confirmation window (`confirmationSeconds`, ~60s) during which the output and process must stay unchanged. Any new output, input, lifecycle change, or PID change cancels the pending hibernation. This is why a small `idleSeconds` is safe: a freshly idle agent that resumes work on its own is never killed mid-task.

So with the defaults, hibernation only affects power users running more than 12 agents at once, and even then only ~1 minute after an agent has gone quiet off-screen.

### What gets killed and how it comes back

cmux sends `SIGTERM` to the agent's process group (scoped to that workspace and surface), then swaps the live terminal for a lightweight placeholder, releasing the terminal's memory and CPU. When you visit the tab again, cmux runs the agent's native resume command with the saved session ID, so the session continues where it left off. The placeholder also shows a Resume button as a manual fallback.

### Enable and configure

Enable from the command palette (`⌘⇧P` -> **Enable Agent Hibernation**), from **Settings > Terminal > Agent Hibernation**, or from the CLI:

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

## Troubleshooting

Run `cmux hooks <agent> install --yes` to reinstall one integration. Run `cmux hooks <agent> uninstall --yes` before editing generated files by hand.

If Feed shows nothing, confirm the terminal has `CMUX_SURFACE_ID` and the hook file contains a `cmux hooks feed --source <agent>` command or OpenCode feed plugin. Pi, OMP, Campfire, and Rovo Dev currently provide lifecycle and restore hooks only, so they do not create Feed approval cards. Amp's bundled plugin reports live tab-status updates (idle / thinking / running / reading / done / error / interrupted) and lifecycle restore but does not create Feed approval cards.

If relaunch does not resume an agent, check `~/.cmuxterm/<agent>-hook-sessions.json` for the saved session and verify the agent's resume command still works outside cmux.
