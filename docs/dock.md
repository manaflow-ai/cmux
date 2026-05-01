# Dock

Dock lets you pin TUIs into the right sidebar. Each Dock control runs as its own Ghostty terminal section, so tools keep normal terminal keyboard behavior such as arrow keys, `j` / `k`, and `Ctrl-C`. Feed stays available as the right-sidebar Feed on `Ctrl-4`; Dock is the separate TUI surface on `Ctrl-5` when the right sidebar is focused.

Dock starts each command inside the terminal's non-interactive login shell. That keeps normal login PATH and toolchain setup without running prompt code before the TUI starts. When the command exits, Dock drops into an interactive login shell in the same section.

Dock is configured with JSON. Add a Feed control to run the keyboard-first Feed TUI there:

```json
{
  "controls": [
    {
      "id": "feed",
      "title": "Feed",
      "command": "cmux feed tui"
    }
  ]
}
```

`cmux feed tui` is the keyboard-first OpenTUI version of Feed. It runs in the alternate screen, preserves the Dock control's workspace cwd, and shows a latest-first timeline of permission requests, plans, questions, and activity. Use `j` / `k` or arrow keys to move, Enter to accept the default action, `d` to deny, `f` to send replan feedback, `r` to refresh, and `q` or `Ctrl-C` to quit.

OpenTUI currently runs through Bun. On first launch, cmux prepares `~/.cmuxterm/feed-tui-opentui` and installs `@opentui/core` there. Run `cmux feed tui --opentui` to dogfood OpenTUI in isolation. If Bun is missing or the install fails, the default `cmux feed tui` falls back to the legacy Feed TUI so the command still opens.

## Team Config

Commit `.cmux/dock.json` in a repo to share controls with teammates:

```json
{
  "controls": [
    {
      "id": "feed",
      "title": "Feed",
      "command": "cmux feed tui"
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

The order of `controls` is the order shown in Dock. Reorder entries in the file to reorder Dock controls. Remove an entry from the file to remove it from Dock.

`height` is optional and acts as a preferred minimum. Dock expands controls to use the available sidebar height. Controls without a `height` split the remaining space after fixed-height controls are placed.

cmux looks for config in this order:

1. `.cmux/dock.json` in the current project or a parent directory
2. `~/.config/cmux/dock.json`

If neither file exists, Dock opens empty and offers to create a starter config. cmux does not add any Dock controls automatically.

Relative `cwd` values resolve from the repo root for `.cmux/dock.json` and from the home directory for the global config.

## Trust

Project Dock configs start commands automatically after they are trusted. The first time cmux sees a project Dock config, it shows a trust gate before starting commands. Changing the config changes the trust fingerprint and asks again.

Global Dock config at `~/.config/cmux/dock.json` is treated as personal config and starts without a project trust gate.

## Naming

The product name is **Dock**. A single entry is a **Dock control**. Suggested launch phrase:

> Bring your team's TUIs into the cmux Dock.

Other names that still fit the feature: **TUI Dock**, **Command Dock**, **Control Dock**, **Deck**, and **Sidecar**.
