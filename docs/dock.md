# Dock

Dock is the cmux right sidebar rendered as a full panel container. It uses the **same surface and split system as the main content area** — terminals *and* browsers, tiled with the same split affordances — just docked on the right. Each Dock terminal runs in its own Ghostty-backed surface, so TUIs keep normal keyboard behavior such as arrow keys, `j` / `k`, and `Ctrl-C`. Dock browsers share the same browser stack as main-area browser panes (cookies, profile, devtools, navigation).

Dock is useful for project dashboards, git views, logs, queues, local services, test watchers, dev servers, custom TUIs, and reference web pages.

Dock is enabled by default for every installation, including existing users who never enabled its former beta toggle. The old toggle is ignored after upgrading; to keep Dock out of the mode bar, use Settings > Sidebar > Right Sidebar Tabs (or the mode bar's tab customization menu) to hide it. This visibility choice does not delete Dock layouts or persisted Dock state.

Every cmux window has its own independent Dock. Multiple windows can show their Docks side by side, and closing a window closes its Dock terminals and browsers with it. Dock state is part of the normal cmux session snapshot, so quitting or installing an update preserves each workspace Dock and each window Dock.

Each terminal command starts inside the terminal's non-interactive login shell. That keeps the user's normal PATH and toolchain setup without running prompt code before the TUI starts. When the command exits, Dock drops into an interactive login shell in the same section so the user can inspect, rerun, or exit.

## In-app panes (no config required)

You do not need to edit JSON to use Dock. The Dock tab bar carries the same split affordances as the main area:

- **New Terminal** / **New Browser** add a surface to the focused Dock pane.
- **Split Right** / **Split Down** tile the Dock into a Bonsplit tree; each new pane offers New Terminal / New Browser.
- Tabs can be reordered, moved between Dock panes, and closed like main-area tabs.

The Dock toolbar `+` menu and an empty Dock pane offer the same New Terminal / New Browser actions. The optional `dock.json` config only **seeds** the initial Dock layout.

After a Dock has been saved in a session, cmux restores that snapshot instead of seeding it again. Restore includes the split and tab layout, divider positions, tab order and selection, terminal session metadata and agent resume state, and browser navigation, zoom, profile, developer tools, and mute state. An intentionally empty saved Dock also stays empty after relaunch.

When a Dock pane has keyboard focus, the standard creation/split shortcuts act on the Dock instead of the main content area: New Browser (Cmd+Shift+L), New Surface (Cmd+T), and Split Right / Split Down (Cmd+D / Cmd+Shift+D) create or split inside the focused Dock pane. When the main area is focused, the same shortcuts behave as usual.

## CLI

The Rust `cmux` has no Dock placement yet. The old `new-pane --placement dock`, `new-surface --placement dock`, `tree`, `list-panes`, and `list-pane-surfaces` verbs were removed with the Swift CLI (see [plans/cmux-next/cli.md](../plans/cmux-next/cli.md)). To show the Dock from a script, run the app action:

```sh
cmux sidebar show-dock
```

Existing surface-addressed terminal verbs accept these Dock surface IDs directly. In particular, `send`, `send-key`, `read-screen`, `capture-pane`, `focus`, and `close` can target a Dock terminal by its bare surface ID in either Dock scope. No Dock-specific addressing syntax is required.

## Configuration

Dock is configured with JSON:

```json
{
  "controls": [
    {
      "id": "git",
      "title": "Git",
      "command": "lazygit",
      "cwd": ".",
      "height": 300
    },
    {
      "id": "tests",
      "title": "Tests",
      "command": "pnpm test --watch",
      "cwd": ".",
      "height": 260,
      "env": {
        "CI": "0"
      }
    },
    {
      "id": "logs",
      "title": "Logs",
      "command": "tail -f ./logs/development.log"
    },
    {
      "id": "docs",
      "title": "Docs",
      "type": "browser",
      "url": "http://127.0.0.1:8877/sidebar",
      "chrome": false
    }
  ]
}
```

Fields:

- `id`: stable unique identifier for the control.
- `title`: label shown on the Dock tab.
- `type`: optional, `terminal` (default) or `browser`.
- `command`: command to run in the Dock terminal. Required for `terminal` controls.
- `url`: page to open. Required for `browser` controls.
- `chrome`: optional browser chrome visibility. Defaults to `true`; set it to `false` for a chromeless browser pane without an address bar or toolbar.
- `cwd`: optional working directory (terminal controls).
- `height`: optional requested control height in points. Controls without a height share remaining space.
- `env`: optional non-secret environment variables passed only to that control (terminal controls).

Existing terminal-only configs (no `type`) keep loading unchanged. The order of `controls` seeds the initial Dock layout top-to-bottom; once open, you can re-tile, add, and close Dock panes in-app without editing the file.

For a browser control with `chrome: false`, **Focus Address Bar** is intentionally a no-op. Navigation remains available through the page and through `cmux browser <tab_id> navigate <url>` and `cmux browser <tab_id> reload`.

## Config Precedence

cmux looks for Dock config in this order:

1. `.cmux/dock.json` in the current project or a parent directory
2. `~/.config/cmux/dock.json`

Use `.cmux/dock.json` for repo-specific controls that should be shared with teammates. Commit it to the repo when the commands are safe and portable.

Use `~/.config/cmux/dock.json` for personal defaults, machines without a repo, or controls that are specific to your local setup.

Nested project configs apply to their directory tree. If a nested project has its own `.cmux/dock.json`, use that nearest config for work inside the nested project. Do not put unrelated project controls into the global config just because a repo is absent.

If neither file exists, Dock opens empty and offers a prompt to create a starter config. cmux does not add Dock controls automatically.

`dock.json` is an initial seed, not an overlay on a restored session. A restored Dock snapshot takes precedence, including an empty snapshot, so config controls are not duplicated or used to replace panes that were open at quit. Config seeding runs only for a Dock with no saved snapshot, such as a new workspace/window or a legacy session created before Dock persistence. Explicitly reloading the Dock config still replaces the current Dock with the config contents.

Relative `cwd` values resolve from the config base. For `.cmux/dock.json`, that base is the project directory containing `.cmux`. For the global config, that base is the home directory.

## Trust

Project Dock configs can start commands. The first time cmux sees a project Dock config, it shows a trust gate before launching controls. Changing the config changes the trust fingerprint and asks again.

Global Dock config at `~/.config/cmux/dock.json` is treated as personal config and starts without a project trust gate.

Do not put secrets, tokens, or machine-specific private paths in a shared project Dock config. Read secrets from the user's shell, local env files, or existing dev tooling.

## Agent Setup

When asking a coding agent to create a Dock config, point it at this document. The agent should inspect the project first, choose project config or global config deliberately, ask the user when the desired controls are unclear, validate the JSON, and summarize each command before the user trusts the config.

## Naming

The product name is **Dock**. A single entry is a **Dock control**. Suggested launch phrase:

> Bring your team's TUIs into the cmux Dock.

Other names that still fit the feature: **TUI Dock**, **Command Dock**, **Control Dock**, **Deck**, and **Sidecar**.
