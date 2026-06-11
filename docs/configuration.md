# cmux.json settings

Global app preferences live in `~/.config/cmux/cmux.json`.

## `app.confirmQuit`

Controls when cmux asks before quitting:

- `always`: show the quit confirmation on Cmd+Q or app quit.
- `dirty-only`: show it only when a workspace has a terminal or panel that reports close confirmation is needed.
- `never`: quit immediately.

Default: `always` for stable and nightly builds. DEV builds always behave as `never`, regardless of the file setting, so tagged development builds can be replaced without a full-screen quit dialog.

The older boolean `app.warnBeforeQuit` still works as a fallback when `app.confirmQuit` is not set. `true` maps to `always`; `false` maps to `never`.

## `app.forkConversationDefaultDestination`

Controls what the tab right-click `Fork Conversation` item does. The submenu still exposes every destination.

Values: `right`, `left`, `top`, `bottom`, `newTab`, `newWorkspace`.

Default: `right`.

## `terminal.agentHibernation`

Opt-in Agent Hibernation. cmux kills idle background agent processes to free RAM and CPU, then resumes each one with its saved session when you visit its tab. See [agent-hooks.md](agent-hooks.md#agent-hibernation) for the full behavior, including the confirmation settle window and how resume works.

```json
{
  "terminal": {
    "agentHibernation": {
      "enabled": true,
      "idleSeconds": 5,
      "maxLiveTerminals": 12
    }
  }
}
```

- `enabled`: turn Agent Hibernation on. Default: `false`.
- `idleSeconds`: seconds a background idle agent terminal must be quiet before it can hibernate. A ~60s confirmation settle window still applies on top of this. Default: `5`. Range: `5`-`604800`.
- `maxLiveTerminals`: how many live restorable agent terminals to keep before cmux hibernates the oldest idle background ones. Nothing hibernates while you are at or under this count. Default: `12`. Range: `1`-`256`.

Enable it from the command palette (`⌘⇧P` -> Enable Agent Hibernation), from **Settings > Terminal > Agent Hibernation**, or with `cmux agent-hibernation on`.

## `terminal.surfaceHibernation`

Surface Hibernation frees the terminal renderer (Metal buffers, render threads, PTY) of idle plain-shell terminals in hidden workspaces. cmux captures the scrollback and working directory first, and when you visit the terminal again it starts a fresh shell in that directory with the scrollback replayed. It also enforces a least-recently-used cap on how many terminal surfaces stay live at once, so background workspaces cannot accumulate unbounded memory.

A terminal is only reclaimed when it is off-screen, safely at a shell prompt with no foreground process, no background jobs, and no listening ports, quiet for the idle window, and its output has stayed unchanged for a ~60s confirmation settle window. Agent terminals (covered by Agent Hibernation), remote terminals, tmux-bound terminals, and terminals with pending startup work or queued input are never reclaimed.

```json
{
  "terminal": {
    "surfaceHibernation": {
      "enabled": true,
      "idleSeconds": 300,
      "unmountedIdleSeconds": 1800,
      "maxLiveSurfaces": 12
    }
  }
}
```

- `enabled`: turn Surface Hibernation on. Default: `true`.
- `idleSeconds`: seconds a background shell terminal must be quiet before the live-surface cap may reclaim it. Default: `300`. Range: `30`-`604800`.
- `unmountedIdleSeconds`: seconds a workspace must stay hidden — with its terminal quiet — before its idle shell surfaces hibernate even without cap pressure. Default: `1800`. Range: `60`-`2592000`.
- `maxLiveSurfaces`: how many terminal surfaces may stay live at once before cmux hibernates the oldest eligible background ones. Every live surface counts toward the limit; only idle, non-busy, non-visible ones are reclaimed. Default: `12`. Range: `1`-`256`.

Toggle it from the command palette (`⌘⇧P` -> Surface Hibernation), from **Settings > Terminal > Surface Hibernation**, or with `cmux surface-hibernation <on|off>`.

## `diffViewer.defaultLayout`

Controls the initial layout for newly opened diff viewers.

Values: `unified`, `split`.

Default: `unified`.

```json
{
  "diffViewer": {
    "defaultLayout": "unified"
  }
}
```

The toolbar layout toggle persists the last user choice for future generated diff viewers. Passing `cmux diff --layout split` or `cmux diff --layout unified` overrides both the saved toolbar choice and this default for that invocation.
