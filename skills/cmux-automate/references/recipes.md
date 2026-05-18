# cmux Automation Recipes

Use these as starting points. Prefer project-local `.cmux/` files for repo
workflow automation.

## Current Workspace to Reusable Command

1. Inspect the active layout:

   ```bash
   cmux identify --json
   cmux tree
   ```

2. Write a `.cmux/cmux.json` `commands[]` entry that recreates the useful
   terminal, browser, and split layout.
3. Add a Command Palette action only if the command should be surfaced as a
   named action or tab bar button.

## Plus Button as Workflow Launcher

Use left-click for the default workflow and right-click for alternatives:

`.cmux/cmux.json`:

```json
{
  "actions": {
    "default-dev": {
      "type": "workspaceCommand",
      "title": "Default Dev",
      "commandName": "Default Dev"
    },
    "review-pr": {
      "type": "workspaceCommand",
      "title": "Review PR",
      "commandName": "Review PR"
    }
  },
  "ui": {
    "newWorkspace": {
      "action": "default-dev",
      "contextMenu": [
        { "action": "default-dev", "title": "Default Dev" },
        { "action": "review-pr", "title": "Review PR" },
        { "type": "separator" },
        { "action": "cmux.newTerminal", "title": "New Terminal" },
        { "action": "cmux.newBrowser", "title": "New Browser" }
      ]
    }
  }
}
```

Always define matching `commands[].name` entries for every `workspaceCommand`.

## Dev Workspace with Browser and Dock

Use `.cmux/cmux.json` for the workspace command and `.cmux/dock.json` for
long-running controls:

`.cmux/cmux.json`:

```json
{
  "commands": [
    {
      "name": "Default Dev",
      "workspace": {
        "name": "Dev",
        "cwd": ".",
        "layout": {
          "direction": "horizontal",
          "children": [
            {
              "pane": {
                "surfaces": [
                  { "type": "terminal", "name": "Server", "command": "bun dev" }
                ]
              }
            },
            {
              "pane": {
                "surfaces": [
                  { "type": "browser", "name": "Preview", "url": "http://localhost:3000" }
                ]
              }
            }
          ]
        }
      }
    }
  ]
}
```

`.cmux/dock.json`:

```json
{
  "controls": [
    { "id": "tests", "title": "Tests", "command": "bun test --watch", "cwd": ".", "height": 280 },
    { "id": "git", "title": "Git", "command": "lazygit", "cwd": ".", "height": 320 },
    { "id": "feed", "title": "Feed", "command": "cmux feed tui --opentui", "height": 260 }
  ]
}
```

## PR Review Workspace

Good ingredients:

- Terminal: `gh pr status`, `gh pr view --web`, or a local review command.
- Browser: PR URL or checks URL.
- Markdown: `cmux markdown open REVIEW.md` for notes.
- Sidebar: `cmux set-status review "in progress"` and `cmux log`.

## CI Watch Dock

Good controls:

`.cmux/dock.json`:

```json
{
  "controls": [
    {
      "id": "gh-runs",
      "title": "GitHub Runs",
      "command": "gh run list --limit 10; latest=$(gh run list --limit 1 --json databaseId --jq '.[0].databaseId // empty'); test -n \"$latest\" && gh run watch \"$latest\"",
      "cwd": ".",
      "height": 260
    },
    {
      "id": "feed",
      "title": "Feed",
      "command": "cmux feed tui --opentui",
      "height": 260
    }
  ]
}
```

## Bug Repro Workspace

Good ingredients:

- Terminal for the repro command.
- Browser preview with console and errors available through `cmux browser`.
- Markdown notes panel with reproduction steps.
- Status/progress updates from the repro script.
- `cmux trigger-flash` when the repro reaches the step needing human attention.

## Agent Hook Automation

Use hooks when users want agent activity to update cmux automatically:

```bash
cmux hooks setup --yes
cmux feed tui --opentui
```

Useful outcomes:

- Permission prompts and questions show in Feed.
- Agent completion sends notifications.
- Scripts can call `cmux set-status`, `cmux set-progress`, and `cmux log` from
  hook handlers or wrapper scripts.
