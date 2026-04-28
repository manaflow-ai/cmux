# Dock

Dock lets you pin TUIs into the right sidebar. Each Dock control runs as its own Ghostty terminal section, so tools keep normal terminal keyboard behavior such as arrow keys, `j` / `k`, and `Ctrl-C`.

The built-in Dock starts with Feed:

```json
{
  "controls": [
    {
      "id": "feed",
      "title": "Feed",
      "command": "cmux feed tui",
      "height": 320
    }
  ]
}
```

`cmux feed tui` is the keyboard-first version of Feed. It lists permission requests, plans, questions, and activity. Use `j` / `k` or arrow keys to move, Enter to accept the default action, `d` to deny, `f` to send replan feedback, `r` to refresh, and `q` or `Ctrl-C` to quit.

## Team Config

Commit `.cmux/dock.json` in a repo to share controls with teammates:

```json
{
  "controls": [
    {
      "id": "feed",
      "title": "Feed",
      "command": "cmux feed tui",
      "height": 320
    },
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
    }
  ]
}
```

The order of `controls` is the order shown in Dock. Reorder entries in the file to reorder Dock sections. Omit the built-in `feed` entry if the team does not want it.

cmux looks for config in this order:

1. `.cmux/dock.json` in the current project or a parent directory
2. `~/.config/cmux/dock.json`
3. the built-in Feed control

Relative `cwd` values resolve from the repo root for `.cmux/dock.json` and from the home directory for the global config.

## Trust

Project Dock configs start commands automatically after they are trusted. The first time cmux sees a project Dock config, it shows a trust gate before starting commands. Changing the config changes the trust fingerprint and asks again.

Global Dock config at `~/.config/cmux/dock.json` is treated as personal config and starts without a project trust gate.

## Naming

The product name is **Dock**. A single entry is a **Dock control**. Suggested launch phrase:

> Bring your team's TUIs into the cmux Dock.

Other names that still fit the feature: **TUI Dock**, **Command Dock**, **Control Dock**, **Deck**, and **Sidecar**.
