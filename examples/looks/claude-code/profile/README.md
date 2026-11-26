# Claude Code app profile

The whole Claude Code desktop app in one install, not only its look: the
[whole](../whole) look (theme, project sidebar, transcript, one-line composer, New Tab home,
usage section, Session Info status line) with every Claude Code feature look's settings, actions
and keys, Claude's prompts in the composer's / menu, its attach and / buttons on the composer, its
searchable model picker with effort apart, and its send pop.

```sh
cmux setup install github.com/manaflow-ai/cmux/examples/looks/claude-code/profile
```

Opt-in: nothing changes until you install it, and `cmux setup remove manaflow-ai/claude-code-profile`
puts everything back. Built only from the public customization docs
([looks README](../../README.md), [setup repos](../../../../docs/cmux-next/setup-repos.md), the
[settings catalog](../../../../docs/mdm/managed-preferences.md) and the interface files the looks
README points at).

## What it combines

| From | Brings |
| --- | --- |
| [whole](../whole) | theme, sidebar, transcript, composer ring, New Tab home, usage, status line, its keys |
| [modes](../modes) | Plan toggle (`cmd+j p`), Start in Plan mode action |
| [composer-controls](../composer-controls) | `opt+p` model, `cmd+j a` add menu |
| [cloud](../cloud) | desktop continue and teleport actions, `cmd+j c` computer |
| [cli](../cli), [agents](../agents) | start, resume and agents-view actions |
| [export](../export), [side-question](../side-question) | `cmd+j x` copy conversation, `cmd+;` side question |
| [notification-levels](../notification-levels) | permission banner, question badge |
| [session-worktree](../session-worktree), [inactive-archive](../inactive-archive), [open-in-editor](../open-in-editor) | worktrees in `.claude/worktrees`, 7-day archive, citations open in the editor |
| [send-pop](../send-pop) | `agentPane.display.sendPop` |

Where two looks bind the same key, whole wins: `cmd+shift+m` opens the mode menu
(`agentPane.setMode`), and the transcript stays 800 pt wide, not transcript-width's 640.
[session-recents](../session-recents) is left out (gap a below).

## Checklist

Each feature of the reference app (features first, then motion), matched, partial, or a gap
sent to the customization lead. Gap letters are the lines sent.

| Feature | Area | Status | How, or the gap |
| --- | --- | --- | --- |
| [Cmd-N starts a new session](https://code.claude.com/docs/en/desktop) | keyboard | matched | keybindings.json cmd+n palette.newAgentChat {harness: claude} |
| [Cmd-Shift-M opens the permission mode menu (Ask, Auto accept edits, Plan, Bypass)](https://code.claude.com/docs/en/desktop) | keyboard | matched | keybindings.json cmd+shift+m agentPane.setMode |
| [Cmd-/ shows every shortcut](https://code.claude.com/docs/en/desktop) | keyboard | matched | keybindings.json cmd+slash keybindings.open |
| [Esc stops Claude's response](https://code.claude.com/docs/en/desktop) | keyboard | matched | cmux's own Esc in the chat (no binding needed) |
| [Model picker from a key, searchable](https://code.claude.com/docs/en/desktop) | model_effort_picker | matched | cmd+shift+i and opt+p agentPane.switchModel; customize/ cmux.composer.model.picker/1 modelMenu search |
| [Effort control apart from the model](https://code.claude.com/docs/en/desktop) | model_effort_picker | partial | cmux.composer.model.picker/1 reasoningMenu separate; cmd+shift+e agentPane.setEffort; gap (f): agentPane.setEffort from a key may need --effort (unverified) |
| [Mode and model chips under the prompt box, outside it](https://code.claude.com/docs/en/desktop) | composer | gap | gap (h): no setting or interface moves the mode and model chips outside the box |
| [One-line prompt box, 'Type / for commands'](https://code.claude.com/docs/en/desktop) | composer | partial | agent-pane/theme.css paints the one-line #303030 box; the placeholder text is cmux's |
| [Voice dictation](https://code.claude.com/docs/en/desktop) | composer | gap | gap (i): no interface or setting for voice dictation in the composer |
| [Slash commands in the prompt box](https://code.claude.com/docs/en/slash-commands) | slash_commands | matched | Claude's own / commands pass through; customize/ cmux.composer.command/1 adds /review /pr /test /explain; toolbar Commands button |
| [Attach images and files, drag and drop](https://code.claude.com/docs/en/desktop) | attachments | matched | cmux composer attachments; customize/ cmux.composer.toolbar/1 Add files button |
| [@-mention files](https://code.claude.com/docs/en/desktop) | attachments | partial | cmux composer @ file mentions (built in); not yet captured beside the app |
| [Panes: chat, diff, browser, terminal, file, plan, tasks side by side](https://code.claude.com/docs/en/desktop) | panels | gap | gap (j): no layout preset arranges chat, diff, browser, terminal and tasks panes side by side |
| [Preview pane with the dev server's page](https://code.claude.com/docs/en/desktop) | panels | partial | cmux browser pane opens beside the chat; no preview toggle key; gap (j): no layout preset arranges chat, diff, browser, terminal and tasks panes side by side |
| [Changes card with +/- counts, Cmd-Shift-D diff pane, Create PR](https://code.claude.com/docs/en/desktop) | diff_review | partial | /pr slash command; cmux's diff viewer; no +/- card or diff toggle key |
| [Comments on the diff, sent with Cmd-Enter](https://code.claude.com/docs/en/desktop) | diff_review | gap | gap (k): no inline comments on a diff that go back to the agent |
| [Plan mode](https://code.claude.com/docs/en/desktop) | plan_mode | matched | cmd+j p agentPane.composer.togglePlan; action claude-code-plan (--permission-mode plan); cmd+shift+m mode menu |
| [Plan pane](https://code.claude.com/docs/en/desktop) | plan_mode | gap | gap (l): no plan or tasks pane beside the chat |
| [Tasks pane with the agent's todos](https://code.claude.com/docs/en/desktop) | status | gap | gap (l): no plan or tasks pane beside the chat |
| [Worked for Ns, time and token footer](https://code.claude.com/docs/en/desktop) | status | partial | customize/ cmux.session.info.section/1 status line in Session Info, not under the turn |
| [Context usage ring](https://code.claude.com/docs/en/desktop) | status | matched | agentPane.showContextUsage true; agentPane.composerRing context |
| [Notifications when Claude needs permission or finishes](https://code.claude.com/docs/en/settings) | status | matched | notifications.delivery.permissionRequest banner, .question badge, .taskComplete off |
| [Sessions grouped by project, subagents nested](https://code.claude.com/docs/en/desktop) | sidebar | matched | sidebar.groupBy folder; sidebar.sessionTree true; 284 pt sidebar |
| [No Home or App Store rows above the sessions](https://code.claude.com/docs/en/desktop) | sidebar | matched | sidebar.sections.hidden ["sec_top"] hides Home, App Store and coderouter; Settings and the account stay in the bottom row |
| [Recent sessions list](https://code.claude.com/docs/en/desktop) | sidebar | partial | the New Tab home lists recents (renderHome); the Recents sidebar section (claude-code/session-recents) cannot ship beside Usage: gap (a): a look ships one customize app, one export per interface; Recents and Usage cannot both be cmux.section/1 |
| [Worktree per session in .claude/worktrees](https://code.claude.com/docs/en/desktop) | sessions | matched | agentPane.sessionWorktrees project |
| [Continue a CLI session in the desktop app; teleport a cloud session](https://code.claude.com/docs/en/desktop) | sessions | matched | actions claude-code-desktop-continue, claude-code-teleport; cmd+j c chooseComputer |
| [Background agents view](https://code.claude.com/docs/en/desktop) | sessions | matched | action claude-code-agents |
| [Side question without leaving the thread](https://code.claude.com/docs/en/desktop) | keyboard | matched | cmd+semicolon agentPane.sideQuestion |
| [Open a cited file at its line in the editor](https://code.claude.com/docs/en/desktop) | panels | matched | agentPane.links.openCitationsInEditor true |
| [Copy the conversation](https://code.claude.com/docs/en/desktop) | status | matched | cmd+j x agentChat.copyConversation |
| [Account switching](https://code.claude.com/docs/en/desktop) | account_switching | gap | gap (m): no setting places an account switcher; switching never captured |
| [Settings page](https://code.claude.com/docs/en/desktop) | settings | gap | gap (n): a look cannot restyle cmux Settings |

| Motion | Reference | Status | How, or the gap |
| --- | --- | --- | --- |
| Sent prompt pops in and settles | pop past size ~0.25% at 300 ms, settles by 450 ms (measured, claude-code/send-pop) | matched | agentPane.display.sendPop true |
| Sidebar opens and closes | unmeasured | partial | ui.animations.sidebar on (cmux's timing); gap (b): a look cannot set motion durations or easings |
| Model picker opens | unmeasured | partial | ui.animations.overlays on (cmux's timing); gap (b): a look cannot set motion durations or easings |
| Streaming text arrives | unmeasured | partial | cmux's streaming; gap (b): a look cannot set motion durations or easings |
| Panes drag and reorder | unmeasured | partial | ui.animations.panes on (cmux's timing); gap (b): a look cannot set motion durations or easings |
| Hover and press | unmeasured | partial | ui.animations.feedback on (cmux's timing); gap (b): a look cannot set motion durations or easings |
| Working spinner | unmeasured | partial | ui.animations.indicators on (cmux's timing); gap (b): a look cannot set motion durations or easings |
