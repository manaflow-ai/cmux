# Dock

Dock is the cmux right sidebar rendered as a full panel container. It uses the **same surface and split system as the main content area** — terminals *and* browsers, tiled with the same split affordances — just docked on the right. Each Dock terminal runs in its own Ghostty-backed surface, so TUIs keep normal keyboard behavior such as arrow keys, `j` / `k`, and `Ctrl-C`. Dock browsers share the same browser stack as main-area browser panes (cookies, profile, devtools, navigation).

Dock is useful for project dashboards, git views, logs, queues, local services, test watchers, dev servers, custom TUIs, and reference web pages. Feed can be added as one optional terminal with `cmux feed tui --opentui`, but Dock is not limited to Feed.

Each terminal command starts inside the terminal's non-interactive login shell. That keeps the user's normal PATH and toolchain setup without running prompt code before the TUI starts. When the command exits, Dock drops into an interactive login shell in the same section so the user can inspect, rerun, or exit.

## In-app panes (no config required)

You do not need to edit JSON to use Dock. The Dock tab bar carries the same split affordances as the main area:

- **New Terminal** / **New Browser** add a surface to the focused Dock pane.
- **Split Right** / **Split Down** tile the Dock into a Bonsplit tree; each new pane offers New Terminal / New Browser.
- Tabs can be reordered, moved between Dock panes, and closed like main-area tabs.

The Dock toolbar `+` menu and an empty Dock pane offer the same New Terminal / New Browser actions. The optional `dock.json` config only **seeds** the initial Dock layout.

When a Dock pane has keyboard focus, the standard creation/split shortcuts act on the Dock instead of the main content area: New Browser (Cmd+Shift+L), New Surface (Cmd+T), and Split Right / Split Down (Cmd+D / Cmd+Shift+D) create or split inside the focused Dock pane. When the main area is focused, the same shortcuts behave as usual.

## CLI / socket

Dock panes are scriptable through the same creation commands as the main area, with `--placement dock`:

```sh
cmux new-pane --placement dock                              # split a terminal into the Dock
cmux new-pane --type browser --placement dock --url https://example.com
cmux new-surface --type browser --placement dock --url https://example.com   # add a Dock tab
```

`--placement` accepts `workspace` (default) or `dock`. The Dock hosts terminal and browser panes only.

Dock-created handles are returned as Dock-scoped response fields: `dock_surface_id` and `dock_pane_id`. The ordinary workspace fields `surface_id` and `pane_id` are `null` for Dock placement, because existing workspace surface and pane RPCs route through the main content split tree.

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
      "url": "https://example.com"
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
- `cwd`: optional working directory (terminal controls).
- `height`: optional requested terminal height in points. Controls without a height share remaining space.
- `env`: optional non-secret environment variables passed only to that control (terminal controls).

Existing terminal-only configs (no `type`) keep loading unchanged. The order of `controls` seeds the initial Dock layout top-to-bottom; once open, you can re-tile, add, and close Dock panes in-app without editing the file.

## Config Precedence

cmux looks for Dock config in this order:

1. `.cmux/dock.json` in the current project or a parent directory
2. `~/.config/cmux/dock.json`

Use `.cmux/dock.json` for repo-specific controls that should be shared with teammates. Commit it to the repo when the commands are safe and portable.

Use `~/.config/cmux/dock.json` for personal defaults, machines without a repo, or controls that are specific to your local setup.

Nested project configs apply to their directory tree. If a nested project has its own `.cmux/dock.json`, use that nearest config for work inside the nested project. Do not put unrelated project controls into the global config just because a repo is absent.

If neither file exists, Dock opens empty and offers a prompt to create a starter config. cmux does not add Dock controls automatically.

Relative `cwd` values resolve from the config base. For `.cmux/dock.json`, that base is the project directory containing `.cmux`. For the global config, that base is the home directory.

## Trust

Project Dock configs can start commands. The first time cmux sees a project Dock config, it shows a trust gate before launching controls. Changing the config changes the trust fingerprint and asks again.

Global Dock config at `~/.config/cmux/dock.json` is treated as personal config and starts without a project trust gate.

Do not put secrets, tokens, or machine-specific private paths in a shared project Dock config. Read secrets from the user's shell, local env files, or existing dev tooling.

## Agent Setup

When asking a coding agent to create a Dock config, tell it to run:

```sh
cmux docs dock
```

The agent should inspect the project first, choose project config or global config deliberately, ask the user when the desired controls are unclear, validate the JSON, and summarize each command before the user trusts the config.

## Naming

The product name is **Dock**. A single entry is a **Dock control**. Suggested launch phrase:

> Bring your team's TUIs into the cmux Dock.

Other names that still fit the feature: **TUI Dock**, **Command Dock**, **Control Dock**, **Deck**, and **Sidecar**.
