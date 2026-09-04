# Skills and Customization Ideas

This is an internal planning note for cmux skills and customization surfaces. Keep public end-user skills in the cmux repo when they teach repeatable user workflows. Keep release, debug, and company operations skills in `cmuxterm-hq`.

## Current Public Skills

- `cmux`: core CLI control for windows, workspaces, panes, surfaces, focus, and routing.
- `cmux-workspace`: current-workspace automation, sidebar metadata, input, and helper surfaces.
- `cmux-settings`: safe reads, writes, validation, and editor open for `~/.config/cmux/cmux.json`.
- `cmux-customization`: user-facing config across actions, plus button, tab bar buttons, workspace layouts, Dock controls, settings, notifications, browser routing, and Ghostty config boundaries.
- `cmux-diagnostics`: support-safe health checks for CLI, socket, hooks, session restore, settings, and agent binaries.
- `cmux-browser`: browser automation inside cmux webview surfaces.
- `cmux-markdown`: formatted markdown panels beside terminals.

## Current Customization Surfaces

- `actions` in `cmux.json`: reusable action IDs for Command Palette, shortcuts, tab bar buttons, and plus-button menus.
- `ui.newWorkspace.action`: replaces the plus-button click.
- `ui.newWorkspace.contextMenu`: controls the plus-button right-click menu. `ui.newWorkspace.rightClick` is accepted as an alias, but public examples should use `contextMenu`.
- `ui.surfaceTabBar.buttons`: replaces the visible tab bar button list. Built-ins must be included explicitly if they should remain visible.
- `commands`: reusable shell commands and workspace layouts for worktrees, multiple checkouts, local services, browser previews, and SSH setups.
- Config precedence: project-local actions and commands override global entries with the same ID or name. Global app preferences stay in `~/.config/cmux/cmux.json`.
- `.cmux/dock.json` and `~/.config/cmux/dock.json`: right-sidebar Dock controls for TUIs, logs, tests, queues, dev servers, and `cmux feed tui --opentui`.
- `cmux-settings` paths: appearance, sidebar behavior, app icon, menu-bar mode, notifications, browser routing, automation, shortcuts, and new-workspace placement.
- cmux CLI workspace metadata: workspace names, descriptions, colors, read/unread state, progress, status pills, and logs.
- Notification hooks in `cmux.json`: filter, rewrite, suppress, or augment notification behavior.
- Ghostty config: terminal fonts, themes, cursor, copy-on-select, shell integration, terminal keybindings, and rendering.

## Skill Candidates

- `cmux-dock`: create `.cmux/dock.json` or global Dock controls after inspecting project scripts, logs, services, and TUIs. This should become a separate skill if Dock setup gets enough schema, trust, and validation detail to make `cmux-customization` too broad.
- `cmux-feed`: diagnose and configure Feed hooks, Feed TUI Dock controls, notification categories, and event stream checks. Keep it separate from diagnostics only if it gains repeatable setup/edit flows beyond read-only health checks.
- `cmux-sidebar`: manage sidebar metadata, workspace descriptions, colors, pinned state, read state, and project conventions. This is useful when sidebar metadata becomes a common integration target for agents and scripts.
- `cmux-ssh`: set up remote workspaces, SSH URL launches, remote browser routing, reconnect behavior, and remote agent notifications.
- `cmux-cloud-vm`: operate Cloud VM create, attach, exec, SSH endpoint, billing, provider, and smoke-test workflows.
- `cmux-vault`: manage vault-backed agent configuration, credential references, and restore behavior without leaking secrets into prompts.

## Distribution Notes

- Vercel `skills` expects each skill in a folder with `SKILL.md` frontmatter containing `name` and `description`. Keep optional `scripts`, `references`, `assets`, and `agents/openai.yaml` next to the skill.
- Standard install is `npx skills add manaflow-ai/cmux -g -y`. Omit `--skill` to install all cmux skills. Use repeated `--skill <name>` flags to install selected skills. Do not use `--all` to mean all skills, because that flag installs to every supported agent.
- Keep end-user cmux skills in the cmux repo for now. A dedicated skills repo only helps if clone/install time becomes painful, or if the skills need a release cadence that should not track the app repo.
- Timing check from this worktree, with `skills@latest` warm in npm cache: local single-skill install took 3.37s, local all-skills install took 4.07s, and remote GitHub single-skill install took 10.91s. These numbers are small enough that a separate repo is not justified yet.

## Product Customization Ideas

- Feed customization: default filter, default decision buttons, feed-to-Dock presets, feed event retention, and per-agent display grouping.
- Dock customization: control groups, reusable presets, default heights, collapsed state, and project templates.
- Sidebar customization: visible fields, metadata row order, workspace grouping, badge policy, color defaults, and per-project sidebar conventions.
- Tab bar customization: button groups, per-surface button sets, icon packs, overflow behavior, and action-specific tooltips.
- Plus-button customization: starter templates for worktrees, multi-checkout setups, SSH launchers, and paired agent layouts.
- Command Palette customization: action categories, keywords, project-local aliases, and discoverability hints for inherited actions.
- Config lifecycle: explicit precedence docs, import/export/reset flows, diff previews, and one-command rollback from a generated backup.
- Team presets: shareable `.cmux/` bundles for repos, including default workspace actions, Dock controls, hooks, and browser previews.
- Agent presets: named Codex, Claude, and custom-agent launchers with default cwd, env, prompt, target pane or tab, and layout.

## Examples Library

Keep the examples library focused on reusable end-user workflows:

- Worktree agents: plus-button click, right-click alternatives, and paired agents.
- Full-stack dev: frontend, tests, browser preview, and Dock controls.
- SSH devbox: remote terminal plus local browser or notes surface.
- Review PR: GitHub terminal, PR browser, and notes or markdown panel.
- Docs workspace: docs dev server, browser preview, and markdown viewer.
- CI watch: GitHub Actions, WarpBuild, Feed TUI, and release monitors.
- Quick agent buttons: Codex and Claude tab bar buttons with Command Palette entries.

Use the Promotion Rule when an example starts to exceed
`cmux-customization`.

## Promotion Rule

Create a new skill when the workflow has setup commands, validation, and safety rules that an agent would otherwise rediscover. Keep an idea in docs when it is just product positioning, a list of possible settings, or a compact `cmux-customization` example. Do not publish private debug windows, release automation, production operations, or company-specific workflows as end-user cmux skills.
