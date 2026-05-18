# Dock

Dock lets you pin terminal controls into the cmux right sidebar. Each Dock control runs a command in its own Ghostty-backed terminal section, so TUIs keep normal keyboard behavior such as arrow keys, `j` / `k`, and `Ctrl-C`.

Dock controls are useful for project dashboards, git views, logs, queues, local services, test watchers, dev servers, and custom TUIs. Feed can be added as one optional control with `cmux feed tui --opentui`, but Dock is not limited to Feed.

Each command starts inside the terminal's non-interactive login shell. That keeps the user's normal PATH and toolchain setup without running prompt code before the TUI starts. When the command exits, Dock drops into an interactive login shell in the same section so the user can inspect, rerun, or exit.

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
    }
  ]
}
```

Fields:

- `id`: stable unique identifier for the control.
- `title`: label shown in the Dock header.
- `command`: command to run in the Dock terminal.
- `cwd`: optional working directory.
- `height`: optional requested terminal height in points. Controls without a height share remaining space.
- `env`: optional non-secret environment variables passed only to that control.

The order of `controls` is the order shown in Dock. Reorder entries in the file to reorder Dock controls. Remove an entry from the file to remove it from Dock.

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
