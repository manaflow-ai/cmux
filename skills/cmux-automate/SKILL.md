---
name: cmux-automate
description: "Suggest and build useful cmux automations for an end user. Use when a user wants to automate repeated workflows, learn what the cmux CLI can do, turn current workspace layouts into reusable commands, add plus-button click or right-click launchers, create Command Palette commands, tab bar buttons, Dock controls, browser/markdown helpers, sidebar status/progress/log updates, notifications, event-driven scripts, hooks, or small project-local scripts backed by cmux CLI commands."
---

# cmux Automation

Use this skill to turn repeated work into cmux-native automation. Start with the
CLI because it is the most composable surface, then persist useful workflows with
project-local config when the user wants repeatable buttons or commands.

## Workflow

1. Audit the current workflow:

   ```bash
   cmux identify --json
   cmux tree
   cmux top
   test -f .cmux/cmux.json && sed -n '1,220p' .cmux/cmux.json
   test -f .cmux/dock.json && sed -n '1,220p' .cmux/dock.json
   ```

   Also inspect project scripts such as `package.json`, `justfile`,
   `Taskfile.yml`, `Makefile`, `.github/workflows`, and existing agent docs.

2. Suggest a short menu of automations, ranked by immediate value. Explain the
   cmux CLI primitives behind each option in concrete terms.
3. Prefer a quick CLI prototype before editing persistent config.
4. Persist accepted automations using the right surface:
   - `.cmux/cmux.json` for project-local actions, commands, workspace layouts,
     plus-button click, plus-button right-click menus, tab bar buttons, and
     Command Palette entries.
   - `.cmux/dock.json` for right-sidebar Dock controls.
   - Small repo scripts for multi-step shell logic that is awkward in JSON.
   - `AGENTS.md` instructions when future agents should use the automation.
5. Validate and reload:

   ```bash
   cmux config validate
   cmux reload-config
   cmux tree
   ```

## Automation Ideas to Suggest

- Current layout to command: recreate the active workspace with `new-workspace`
  or a `commands[].workspace.layout` entry.
- Plus-button launcher: make left-click open the default project workflow with
  `ui.newWorkspace.action`.
- Plus-button right-click menu: expose alternate starters with
  `ui.newWorkspace.contextMenu`, such as Worktree Agents, SSH Devbox, Review PR,
  Docs Workspace, Full-Stack Dev, CI Watch, New Terminal, and New Browser.
- Command Palette commands: add named `actions` or `commands` for repeated
  tasks the user wants available from Cmd+Shift+P.
- Surface tab bar buttons: add one-click Codex, Claude, browser, split, test, or
  custom-agent buttons while preserving built-ins unless the user asks to hide
  them.
- Dock controls: add persistent controls for tests, logs, dev servers, queues,
  `lazygit`, `gh run watch`, CircleCI, deployment monitors, or
  `cmux feed tui --opentui`.
- Browser helpers: script cmux browser surfaces for preview, login checks,
  screenshots, console/errors, cookies, storage, and portable state capture.
- Markdown helpers: open live plans, docs, PR notes, or runbooks with
  `cmux markdown open`.
- Sidebar signals: update status pills, progress, logs, read state, and
  workspace descriptions with CLI commands.
- Notification flows: send, list, open, clear, and mark notifications for
  agent or CI scripts.
- Event-driven scripts: use `cmux events` as NDJSON to react to workspace,
  surface, browser, notification, and Feed events.
- Agent hooks: use `cmux hooks setup` and Feed routing so agent approvals,
  questions, and completion events surface in cmux.
- Remote and VM workflows: use `cmux ssh` and `cmux vm` or `cmux cloud` when
  the user wants remote workspaces or cloud devboxes.

## CLI-First Rules

- Use short refs such as `workspace:2`, `pane:1`, and `surface:7` in examples.
- Use `--json` for scripts and human-readable output for explanations.
- Prefer caller context from `CMUX_WORKSPACE_ID` and `CMUX_SURFACE_ID` when a
  script runs inside cmux.
- Keep focus-neutral defaults unless the user explicitly wants the automation to
  steal focus.
- Use `cmux trigger-flash` for visual confirmation after non-obvious routing.
- Use `cmux docs <topic>` and `cmux <command> --help` before relying on unclear
  syntax.
- Avoid internal/debug/test-only commands unless the user is developing cmux.

## Safety

- Prefer project-local `.cmux/` config for repo workflows. Use global config
  only for personal app-wide preferences.
- Before editing an existing config, create a timestamped backup next to it.
- Do not put secrets in config, action prompts, or command strings. Use env
  vars, shell profiles, or a secret store.
- Do not replace built-in plus-button or tab bar entries unless the user asked
  for a fully custom surface.
- Use `ui.newWorkspace.contextMenu` for new plus-button right-click examples,
  not the older `rightClick` alias.
- Confirm every `workspaceCommand.commandName` matches a `commands[].name`.
- If terminal behavior is owned by Ghostty, use Ghostty config instead of cmux
  automation.

## References

- Read `references/cli-primer.md` when explaining what the cmux CLI can do or
  choosing command primitives.
- Read `references/recipes.md` when the user asks for automation ideas,
  examples, starter workflows, or a reusable project setup.
- Use `../cmux-customization/SKILL.md` when editing `cmux.json` or Dock config.
- Use `../cmux-browser/SKILL.md` for browser-surface automation.
- Use `../cmux-markdown/SKILL.md` for live markdown panels.
