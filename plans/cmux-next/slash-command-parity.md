# Slash command and @ parity: Claude Code, Codex, cmux NEXT

- Claude Code 2.1.330: 117 commands. 51 covered (12 cmux-owned, 36 pass through, 3 cmux GUI answers), 12 caught by cliOnlyCommands, 54 missing.
- Codex CLI 0.171: 62 commands. 18 covered (9 cmux-owned, 5 pass through, 4 cmux GUI answers), 0 caught, 44 missing.
- @: cmux covers files, folders, chats, guest harnesses and extension items. MCP resources, @agent subagents and Codex's `$` trigger are missing.

Leo's ask (2026-10-23): "Likewise, slash commands. I need you guys to be auditing them for at least Claude and Codex, as well as the @ command, you know, the adding files or whatever, and just making sure we're reaching parity and we're reaching the things that we can, right? Like even if it's, like, something like, you know, integrations or whatever. Like we can eventually just add integrations. So that shouldn't stop us."

Audited on 2026-11-23 against origin/feat-cmux-next at 29c78104b96.

## Sources and evidence keys

Command lists:
- Claude: https://code.claude.com/docs/en/commands.md (fetched 2026-11-23). Local binary is 2.1.330.
- Codex: codex-rs/tui/src/slash_command.rs on openai/codex main. Every description in it is also in the local 0.171 binary's strings, so the list matches 0.171. Also https://developers.openai.com/codex/reference/slash-commands.md (the desktop app list; not counted).

Evidence keys used in the tables. Paths under `webviews/src/agent-session/acpmux/` unless they say otherwise.

| Key | Where |
| --- | --- |
| `CC:n` | `cmuxCommands.ts:n` (cmux-owned command entry). `/compact` and `/clear` are cmux fallback rows that send the text on (`cmuxCommands.ts:176-192`). |
| `CLI:n` | `cliOnlyCommands.ts:n`. It runs for Claude only (`cliOnlyCommands.ts:39`). Uses: `access` = the access menu next to +, `terminal` = nothing in cmux. |
| `LOC:n` | `localCommands.ts:n`. Bare command only. Opens a Session Info section, the `/` list, or the Changes tab. |
| `HL` | In Claude's headless `slash_commands` list. Read from a real init that acpmux logged on this VM (Claude 2.1.330, `~/.acpmux/bundles/01a2043b-946b-7044-b47b-8db5bcca74bb/events/000001.ndjson`). acpmux relays that list as `available_commands_update` (`cmux-tui/crates/acpmux/src/claude_stdio/mod.rs:984-1016`). The same init carries `terminal_slash_commands: [doctor, color, focus, reload-plugins]`. No code in this repo reads that field (grep: its only hit is the chat-sim fixture `webviews/test/fixtures/chat-sim/replay-lane-session.ndjson`). |
| `BR:n` | The Codex bridge cmux runs: `cmux-codex-acp` at rev `dfa59bc` (pinned in `cmux-tui/crates/acpmux/Cargo.toml:202`), `src/translator/commands.rs:n`. Its built-ins are at 11-21. Dispatch is at 396-470. Any other `/name` returns `false` and goes to the model as plain text (`commands.rs:470`). |
| `none` | Not in HL or BR, and not in CC, CLI or LOC. Claude answers "isn't available in this environment" (`cliOnlyCommands.ts:3-4`). Codex gets the text as a normal prompt. |

"Pass through" means the harness advertises it and runs it. A cmux-owned name shadows the harness's own command with the same name (`cmuxCommands.ts:193-215`).

## Claude Code

Removed upstream and not counted: `/pr-comments` (removed v2.1.91), `/ultraplan` (removed), `/vim` (removed v2.1.92; still caught at `CLI:18`). `/design consent|revoke` counts once.

| Command | What it does in the CLI | cmux NEXT today | Evidence |
| --- | --- | --- | --- |
| /add-dir | Add a working folder | missing. Extra folders exist only before the first send (`extraFolders.ts:8-12`) | none |
| /advisor | Second-model advisor on/off | passes through | HL |
| /agents | Reminder on how to manage subagents | passes through | HL |
| /artifact-capabilities | Skill: artifact runtime reference | missing. Not advertised here; likely account-gated (unverified) | none |
| /artifact-diagramming | Skill: diagram guidance for artifacts | missing. Same as above (unverified) | none |
| /artifacts | List or attach artifacts | missing | none |
| /auto-mode-setup | Draft auto-mode environment entries | passes through | HL |
| /autocompact | Set the auto-compact window | passes through | HL |
| /autofix-pr | Cloud session that fixes a PR's CI | missing | none |
| /background | Detach to a background agent | missing | none |
| /batch | Skill: parallel large changes | passes through | HL |
| /branch | Branch the conversation here | missing. cmux `/fork` does the same job | none; CC:93 |
| /btw | Side question | cmux-owned | CC:100 |
| /bug | Report a bug | missing | none |
| /cd | Move the session to a folder | cmux-owned | CC:124 |
| /chrome | Claude in Chrome settings | missing (integration) | none |
| /claude-api | Skill: Claude API reference | passes through | HL |
| /claude-in-chrome | Skill: browser task | missing. Not advertised here (unverified why) | none |
| /clear | New empty conversation | passes through (cmux fallback row) | HL; CC:185 |
| /code-review | Skill: review changes | passes through | HL |
| /color | Prompt bar color | caught, terminal | CLI:23 |
| /compact | Summarize to free context | passes through (cmux fallback row) | HL; CC:178 |
| /config | Settings UI, or `key=value` | caught when bare, terminal. `/config k=v` passes through | CLI:31; HL |
| /context | Context usage grid | cmux-owned (harness also takes it) | CC:64; CC:34 |
| /copy | Copy the last reply | missing. Each reply has a Copy button (`conversation/MessageActions.tsx:17`) | none |
| /cost | Alias of /usage | cmux GUI: Session Info usage | LOC:41 |
| /dataviz | Skill: chart design | passes through | HL |
| /debug | Skill: debug logging | passes through | HL |
| /deep-research | Workflow: cited web research | passes through | HL |
| /design | Skill: UI mockups | passes through | HL |
| /design consent, /design revoke | Grant or revoke Claude Design access | passes through (as design-consent, design-revoke) | HL |
| /design-login | Sign in for /design-sync | missing | none |
| /design-sync | Skill: upload a design system | passes through | HL |
| /desktop | Continue in Claude Desktop | missing | none |
| /diff | Review working-tree changes | missing. The Changes tab exists; Codex's /diff already opens it (LOC:47) | none |
| /doctor | Skill: setup checkup | caught, terminal. It is in HL too, but Claude also lists it as terminal-only | CLI:16; HL |
| /effort | Set effort level | passes through. The effort picker is the GUI (`EffortPicker.tsx`) | HL |
| /exit | Exit the CLI | caught, terminal | CLI:25 |
| /export | Export the conversation as text | missing | none |
| /fast | Fast mode on/off | cmux-owned | CC:57 |
| /feedback | Product feedback | missing | none |
| /fewer-permission-prompts | Skill: build an allowlist | passes through | HL |
| /focus | Focus view | caught, terminal | CLI:24 |
| /fork | Copy into a background session | cmux-owned (cmux's fork, not Claude's) | CC:93 |
| /goal | Keep working until a condition holds | passes through. Goal strip shows it (`goal.ts:1-3`) | HL |
| /heapdump | JS heap snapshot | passes through | HL |
| /help | Help and commands | cmux-owned (help sheet). LOC:43 also maps it | CC:165 |
| /hooks | View hooks | missing | none |
| /ide | IDE integrations | caught, terminal | CLI:20 |
| /import | Import Codex/Gemini/Cursor config | cmux-owned. cmux's /import means a different thing, so Claude's is shadowed | CC:78 |
| /init | Write CLAUDE.md | passes through | HL |
| /insights | HTML report on recent sessions | passes through | HL |
| /install-github-app | Install the Claude GitHub App | missing (integration) | none |
| /install-slack-app | Install the Claude Slack app | missing (integration) | none |
| /keybindings | Open the keybindings file | missing (terminal keys; cmux has /help keys) | none |
| /list-agents | List agents Claude can message | missing. Session Info has a subagents section | none |
| /login | Sign in | cmux-owned | CC:145 |
| /logout | Sign out | caught, terminal | CLI:15 |
| /loop | Skill: repeat a prompt | passes through. Goal strip shows a loop (`goal.ts:1-3`) | HL |
| /mcp | Manage MCP servers | cmux GUI: Session Info connectors (bare). `/mcp reconnect x` passes through | LOC:40; HL |
| /memory | Edit CLAUDE.md, auto memory | missing | none |
| /mobile | QR for the mobile app | missing | none |
| /model | Switch model | cmux-owned (picker); `/model x` also goes to Claude | CC:50 |
| /output-style | Switch output style | passes through | HL |
| /passes | Share a free week | missing | none |
| /permissions | Allow/ask/deny rules | caught, access menu | CLI:13 |
| /plan | Enter plan mode | cmux-owned (harness also takes it) | CC:71 |
| /plugin | Plugin manager | missing (integration) | none |
| /plugin-authoring | Skill: write a mod | passes through | HL |
| /powerup | Feature lessons | missing | none |
| /privacy-settings | Privacy settings | caught, terminal | CLI:22 |
| /radio | Lo-fi radio | missing | none |
| /rate-limit-options | Ways to keep working at a limit | missing | none |
| /recap | One-line session summary | passes through | HL |
| /release-notes | Changelog | missing | none |
| /reload-plugins | Reload plugins | passes through, but Claude lists it as terminal-only. Not caught | HL |
| /reload-skills | Re-scan skills | passes through | HL |
| /remote-control | Remote Control from claude.ai | missing. Session Info has cmux's own Remote Control switch (`remoteControl.ts:3`) | none |
| /remote-env | Default cloud environment | missing | none |
| /rename | Rename the session | passes through | HL |
| /restart | Restart to apply an update | missing | none |
| /resume | Resume a session | cmux-owned | CC:137 |
| /review | Alias of /code-review | passes through as an alias (unverified: the alias is not in HL) | HL (code-review) |
| /rewind | Restore a checkpoint | missing. cmux rewinds Cloud chats only (`conversation/turnActions.ts:31-34`) | none |
| /run | Skill: launch the app | passes through | HL |
| /run-skill-generator | Skill: teach /run | passes through | HL |
| /sandbox | Sandbox mode | missing | none |
| /schedule | Cloud scheduled tasks | missing | none |
| /scroll-speed | Wheel speed | missing (terminal only) | none |
| /security-review | Security review of the branch | passes through | HL |
| /setup-bedrock | Bedrock wizard (hidden) | missing | none |
| /setup-vertex | Vertex wizard (hidden) | missing | none |
| /simplify | Skill: cleanup review | passes through | HL |
| /skill-doctor | Skill cost and use | passes through | HL |
| /skills | List skills | missing. The /help sheet lists skills; Codex's /skills opens it (LOC:49) | none |
| /slides | Skill: presentation | missing. Not advertised here (unverified why) | none |
| /stats | Alias of /usage, Stats tab | missing | none |
| /status | Settings on the Status tab | cmux-owned (cmux summary) | CC:117 |
| /statusline | Configure the status line | caught, terminal | CLI:21 |
| /stickers | Stickers | missing | none |
| /stop | Stop an attached background session | missing | none |
| /subtask | Forked background subagent | missing. Closest is cmux `/side` | none; CC:108 |
| /tasks | Background work (alias /bashes) | missing. Session Info has a tasks section and a background tasks panel | none |
| /team-onboarding | Team guide from usage | passes through | HL |
| /teleport | Pull a cloud session here | missing | none |
| /terminal-setup | Shift+Enter binding | caught, terminal | CLI:17 |
| /theme | Color theme | caught, terminal | CLI:19 |
| /tui | Pick the renderer | missing (terminal only) | none |
| /ultrareview | Cloud multi-agent review | missing | none |
| /update-config | Skill: settings change | passes through | HL |
| /upgrade | Upgrade the plan | missing | none |
| /usage | Cost, limits, stats | cmux GUI: Session Info usage (bare) | LOC:42 |
| /usage-credits | Usage credits | missing | none |
| /verify | Skill: build and observe | passes through | HL |
| /voice | Voice dictation | missing. cmux has its own dictation button (`DictationButton.tsx`) | none |
| /web-setup | Connect GitHub for cloud | missing (integration) | none |
| /workflow-authoring | Skill: workflow scripts | passes through | HL |
| /workflows | Workflow progress view | missing | none |

Also in HL, not in the docs: `__remote-workflow`, `workflow-launch-exec` (internal), and the user's own skills. All pass through.

## Codex CLI

The Codex bridge advertises 11 built-ins plus each skill as `$name` (BR:11-21, BR:235-262). `review-branch` and `review-commit` are bridge-only extras, not TUI commands. Not counted: `rollout` and `test-approval` (debug builds only), `debug-m-drop` and `debug-m-update` ("DO NOT USE"). cliOnlyCommands does nothing for Codex (`cliOnlyCommands.ts:39`), so every missing name reaches the model as a prompt.

| Command | What it does in the CLI | cmux NEXT today | Evidence |
| --- | --- | --- | --- |
| /model | Model and effort | cmux-owned | CC:50 |
| /presets | Saved prompts and commands | missing | none |
| /daybreak | Daybreak on/off | missing | none |
| /ide | IDE context | missing | none |
| /permissions | What Codex may do | missing. The access menu next to + does it; not mapped | none |
| /keymap | Remap TUI keys | missing (terminal only) | none |
| /vim | Vim composer | missing (terminal only) | none |
| /setup-default-sandbox | Elevated sandbox setup | missing | none |
| /experimental | Experimental features | missing | none |
| /approve | Approve one auto-review retry | missing | none |
| /memories | Memory use | missing | none |
| /skills | Use skills | cmux GUI: the `/` list (bare). Bridge also has it | LOC:49; BR:20 |
| /import | Import setup from Claude Code | cmux-owned. cmux's /import means a different thing, so Codex's is shadowed | CC:78 |
| /hooks | Lifecycle hooks | missing | none |
| /review | Review changes | passes through (plus review-branch, review-commit) | BR:15-17 |
| /rename | Rename the thread | passes through | BR:20 |
| /new | New chat | missing. New chat is a cmux button; not mapped | none |
| /archive | Archive the session | missing | none |
| /delete | Delete the session | missing | none |
| /resume | Resume a chat | cmux-owned | CC:137 |
| /fork | Fork the chat | cmux-owned | CC:93 |
| /worktree | New worktree conversation | missing. cmux has worktree setup (`worktreeSetup.tsx`); not mapped | none |
| /app | Continue in Codex Desktop | missing | none |
| /init | Write AGENTS.md | missing. Goes to the model as "/init" text | none |
| /compact | Summarize context | passes through | BR:18 |
| /config | Preferences | missing | none |
| /recap | Summarize now | missing | none |
| /plan | Plan mode | cmux-owned (harness also takes it) | CC:71; BR:11 |
| /voice | Voice | missing. cmux dictation exists | none |
| /goal | Set or view a goal | passes through. Goal strip shows it (`goal.ts:1-3`) | BR:19 |
| /agents | Agent command center | missing | none |
| /side | Side conversation | cmux-owned | CC:108 |
| /btw | Side conversation | cmux-owned | CC:100 |
| /copy | Copy the last reply | missing. Copy button exists | none |
| /export | Export as markdown | missing | none |
| /raw | Raw scrollback | missing (terminal only) | none |
| /tui | TUI mode | missing (terminal only) | none |
| /diff | Git diff | cmux GUI: Changes tab (bare) | LOC:47 |
| /mention | Mention a file | missing. cmux's `@` does the job | none |
| /status | Config and token use | cmux-owned (bridge also has it) | CC:117; BR:14 |
| /daemon | Local background server | missing | none |
| /rc (/remote) | Remote control | missing | none |
| /warnings | Retained warnings | missing | none |
| /cd | Change folder | cmux-owned | CC:124 |
| /pwd (/cwd) | Show the folder | missing | none |
| /usage | Usage and limit reset | cmux GUI: Session Info usage (bare) | LOC:48 |
| /debug-config | Config layers | missing | none |
| /title | Terminal title items | missing (terminal only) | none |
| /statusline | Status line items | missing (terminal only) | none |
| /theme | Syntax theme | missing (terminal only) | none |
| /pets (/pet) | Terminal pet | missing (terminal only) | none |
| /mcp | MCP tools, `/mcp login <name>` | cmux GUI: Session Info connectors (bare). Bridge lists tools but ignores `login` (unverified at runtime; BR:443 drops the rest) | LOC:46; BR:12 |
| /apps | Manage apps | missing (integration) | none |
| /plugins | Browse plugins | missing (integration) | none |
| /logout | Log out | passes through | BR:21 |
| /quit | Exit | missing (terminal only) | none |
| /exit | Exit | missing (terminal only) | none |
| /feedback | Send logs | missing | none |
| /ps | Background terminals | missing. Left out on purpose (`localCommands.ts:34-36`) | none |
| /stop (/clean) | Stop background terminals | missing | none |
| /clear | New chat | missing. cmux's fallback row sends "/clear" (CC:185), but the bridge has no clear, so the model gets the text (BR:470). Verified by code reading only | CC:185; BR:396-470 |
| /subagents | Switch subagents | missing. Session Info has a subagents section | none |

## @ mentions

cmux's `@` menu (`mentionMenuModel.ts:8-10`, `mentionItems.ts:310-354`):
- Files and folders from the host's file search, plus recent picks per project (`mentionItems.ts:34-80`). A pick writes `@path` (folders end in `/`) as text (`mentionItems.ts:393-409`).
- Other chats. A pick writes `cmux session "title" (id)` (`mentionItems.ts:405-408`).
- Installed harnesses as read-only guests: `@codex question` (`mentionItems.ts:205-262`).
- Extension items such as `@pr` or `@pr:441`, from installed apps (`composer/extensionMentions.ts:1-6`).
- A remote chat lists chats only, no files (`MentionMenu.tsx:13-14`).

| Feature | Claude Code | Codex | cmux NEXT |
| --- | --- | --- | --- |
| @file | Yes. The file is read into context | Yes. `@` opens file search and inserts the path | Yes. Inserts `@path` as text. Whether Claude expands it to file content over stream-json is unverified; acpmux does not expand it (`claude_stdio/outbound.rs` has no `@` handling) |
| @folder | Yes. Lists the folder | Inserts the path | Yes, with a trailing `/` |
| @ MCP resource (`@server:uri`) | Yes | No (unverified) | Missing |
| @agent (`@agent-name` to call a subagent) | Yes | No | Missing. cmux's `@harness` is a different feature (a guest from another harness) |
| `$` skills | No (skills are `/name`) | Yes. `$` opens skills; the TUI also lists skills under `/` | Partial. Codex skills show in the `/` menu and go out as `/$name` (`slashCommands.ts:62-87`, `Composer.tsx:1558`). Typing `$` opens nothing |
| `$` apps and plugins | No | Yes, per the Codex skills-and-plugins docs (unverified in 0.171) | Missing |
| Other chats | No | No | Yes (cmux only) |
| Extension items | Plugins can add slash commands, not `@` items | No | Yes (cmux only) |

## Gaps, most useful first

1. **Codex `/clear` sends text to the model.** The cmux fallback row assumes every harness takes `/clear`. Smallest fix: in `cmuxCommands.ts`, run `/clear` as a cmux "new chat in this folder" action when the harness does not advertise `clear`. Or add `clear` and `new` to cmux-codex-acp's dispatch (`thread/start`).
2. **Codex has no terminal-only catch.** `/vim`, `/theme`, `/quit`, `/keymap`, `/permissions` and friends cost a model turn. Smallest fix: give `cliOnlyCommands.ts` a Codex table: `permissions`→access, and `keymap vim raw tui title statusline theme pets quit exit` → terminal.
3. **Claude now reports its own terminal-only list, and cmux ignores it.** The init has `terminal_slash_commands`; the hard-coded list misses `/reload-plugins`. Smallest fix, in Rust: acpmux copies the field into the commands update (`_meta.terminalOnly` per entry, next to `_meta.kind` in `claude_stdio/mod.rs:984-1016`). `cliOnlyCommand` reads it and keeps the table as a fallback.
4. **GUI already exists, only the mapping is missing.** One line each in `localCommands.ts`: Claude `diff`→changes, `skills`→commands, `stats`→usage, `tasks` and `bashes`→tasks, `list-agents`→subagents. Codex `ps`→tasks (the reason to skip it no longer holds if the section shows "nothing running"), `subagents` and `agents`→subagents. cliOnly-style notes for Claude `/copy`, `/voice` and `/remote-control`, and for Codex `/new`, `/copy`, `/voice`, `/worktree` and `/mention`, pointing at the existing button.
5. **@ MCP resources.** Claude and other MCP clients can attach `@server:uri`. Smallest fix: a mention provider in the daemon that lists the chat's MCP resources (acpmux already knows the servers for Session Info connectors). The menu takes it as one more extension-style row kind.
6. **Codex bridge built-ins.** `/init`, `/recap`, `/new`, `/archive` and `/feedback` reach the model as text. Smallest fix: in cmux-codex-acp, add `init` and `recap` as fixed prompts, as the TUI does, and `archive` via `thread/archive` (app-server method name unverified).
7. **`$` trigger for Codex.** Codex users type `$skill`. Smallest fix: open the `/` menu filtered to skills when `$` starts a word in a Codex chat. The send path already writes `/$name`.
8. **@agent subagents.** Claude's `@agent-name` calls a subagent. Smallest fix: list the chat's subagent types (Claude's init `agents` field; unverified that it is present) as `@` rows that insert `@agent-name`.
9. **/rewind on local chats.** cmux rewinds Cloud chats only. Smallest fix: map `/rewind` to the per-message Rewind where it is offered, and say "Cloud only" elsewhere. Local file rewind needs Claude's checkpoint control (unverified over stream-json).
10. **/export.** Both harnesses have it. Smallest fix: a cmux-owned `/export` that saves the transcript as markdown. The copy-as-markdown code exists (`richClipboard.ts`).
11. **Integrations (still worth doing).**
    - MCP login and OAuth: Claude `/mcp reconnect|enable|disable` passes through, but there is no GUI for it. Codex `/mcp login <name>` is dropped by the bridge. Fix: a Login button per server in Session Info connectors.
    - Plugins and apps: Claude `/plugin`, Codex `/apps` and `/plugins`. Fix first: map bare forms to Session Info connectors. Then add a plugin browser.
    - Claude `/install-github-app` and `/web-setup`: cmux already has GitHub connect (`github_status`, `GitHubFolders.tsx`). Point the commands there.
    - Claude `/install-slack-app` and `/chrome`, `/claude-in-chrome`: point to cmux's own browser and connectors, or open the vendor OAuth page in the in-app browser.
    - Claude `/hooks` and `/memory`, Codex `/hooks` and `/memories`: list read-only in Session Info first, then edit.
    - Claude `/schedule` and Codex `/goal`-style long runs: cmux has `schedule/`. Map `/schedule` to it.
12. **Account and plan.** Claude `/logout`, `/upgrade`, `/usage-credits`, `/rate-limit-options`, `/passes`. Smallest fix: point them at the account and usage UI cmux already has, instead of "terminal".
13. **Shadowed names.** cmux owns `/import`, `/fork`, `/status` and `/cd`, which also exist in both harnesses with other meanings (Claude `/import` imports Codex config; Claude `/fork` makes a background copy). Not a bug, but the help sheet should say which one runs. Smallest fix: a "cmux's" tag in `composerHelp.ts` rows for these names.

Terminal-only and toy commands (`/tui`, `/scroll-speed`, `/radio`, `/stickers`, `/heapdump`, `/pets`, `/raw`) are left out on purpose. Catching them (gap 2) is enough.
