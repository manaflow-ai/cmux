# Dock

Dock is the cmux right sidebar rendered as a full panel container. It uses the **same surface and split system as the main content area** — terminals *and* browsers, tiled with the same split affordances — just docked on the right. Each Dock terminal runs in its own Ghostty-backed surface, so TUIs keep normal keyboard behavior such as arrow keys, `j` / `k`, and `Ctrl-C`. Dock browsers share the same browser stack as main-area browser panes (cookies, profile, devtools, navigation).

Dock is useful for project dashboards, git views, logs, queues, local services, test watchers, dev servers, custom TUIs, and reference web pages. Feed can be added as one optional terminal with `cmux feed tui --opentui`, but Dock is not limited to Feed.

Every cmux window has its own independent Dock. Opening a new window seeds that window's Dock fresh from your Dock config (exactly like a fresh app launch), multiple windows can show their Docks side by side, and closing a window closes its Dock terminals and browsers with it.

Each terminal command starts inside the terminal's non-interactive login shell. That keeps the user's normal PATH and toolchain setup without running prompt code before the TUI starts. When the command exits, Dock drops into an interactive login shell in the same section so the user can inspect, rerun, or exit.

Dock also supports a plain terminal primitive. A `type: "terminal"` control without a `command` opens an interactive login shell directly, honoring its configured `cwd`, `env`, and `height`.

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
      "id": "shell",
      "title": "Shell",
      "type": "terminal",
      "cwd": ".",
      "height": 240,
      "env": {
        "NODE_ENV": "development"
      }
    },
    {
      "id": "docs",
      "title": "Docs",
      "type": "browser",
      "url": "https://example.com",
      "profile": "52B43C05-4A1D-45D3-8FD5-9EF94952E445"
    }
  ]
}
```

Fields:

- `id`: stable unique identifier for the control.
- `title`: label shown on the Dock tab.
- `type`: optional, `command` (default), `terminal`, or `browser`.
- `command`: command to run in the Dock terminal. Required for command controls. Command controls may omit `type`.
- `url`: page to open. Required for browser controls.
- `profile`: optional cmux browser profile reference. Prefer the stable profile UUID shown by `browser.profiles.list`; unambiguous profile slugs or display names are accepted for compatibility. If absent, Dock uses the default browser profile. Unknown or ambiguous profile references stop the Dock config instead of falling back to another cookie store.
- `cwd`: optional working directory for command and terminal controls.
- `height`: optional requested terminal height in points. Controls without a height share remaining space.
- `env`: optional non-secret environment variables passed only to command and terminal controls.

Dock configs can define up to 64 controls. Each command or terminal control can define up to 64 `env` variables. Larger configs are rejected before the project trust prompt is rendered.

Command controls run through the login-shell wrapper: cmux starts the configured command in a login shell, then drops into an interactive login shell after the command exits. Terminal controls (`type: "terminal"` with no `command`) start as a plain interactive login shell and do not run a command. Project Dock trust prompts show each command or login shell with its effective `cwd` and `env` overrides before cmux opens the controls. Browser controls show each requested URL and profile, including the resolved profile ID for non-default profiles. Trust for browser controls is bound to the resolved profile UUID, so a display-name or slug reference that later points at a different profile asks for trust again.

Existing configs without `type` keep loading unchanged as command controls. Legacy configs that set `type: "terminal"` together with a `command` also keep loading as command controls. The order of `controls` seeds the initial Dock layout top-to-bottom; once open, you can re-tile, add, and close Dock panes in-app without editing the file.

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

Project Dock configs can add command, terminal, and browser controls. The first time cmux sees a project Dock config, it shows a trust gate before launching controls. The gate lists each control: command controls show the command string, `cwd`, and `env`; terminal primitives show "Login shell", `cwd`, and `env`; and browser controls show the URL and profile. Changing the config changes the trust fingerprint and asks again.

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
