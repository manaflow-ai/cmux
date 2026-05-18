# cmux Customization Examples

Use these examples as starting points. Merge only the relevant top-level keys
into the target config file named above each code block. Unlabeled JSON examples
target `cmux.json`. Preserve unrelated sections, then run `cmux reload-config`
when available.

Prefer project-local `.cmux/cmux.json` for team workflows and global
`~/.config/cmux/cmux.json` for personal app preferences.

## Worktree Agents

Use this when the user wants the plus button to open a worktree or checkout
layout, and right-click to offer alternate starters.

```json
{
  "actions": {
    "worktree-agents": {
      "type": "workspaceCommand",
      "title": "Worktree Agents",
      "commandName": "Worktree Agents",
      "icon": { "type": "symbol", "name": "folder.badge.plus" }
    }
  },
  "ui": {
    "newWorkspace": {
      "action": "worktree-agents",
      "contextMenu": [
        { "action": "worktree-agents", "title": "Worktree Agents" },
        { "type": "separator" },
        { "action": "cmux.newTerminal", "title": "New Terminal" },
        { "action": "cmux.newBrowser", "title": "New Browser" }
      ]
    }
  },
  "commands": [
    {
      "name": "Worktree Agents",
      "workspace": {
        "name": "Worktree Agents",
        "cwd": "../worktrees/my-feature",
        "layout": {
          "direction": "horizontal",
          "children": [
            {
              "pane": {
                "surfaces": [
                  { "type": "terminal", "name": "Codex", "command": "codex" }
                ]
              }
            },
            {
              "pane": {
                "surfaces": [
                  { "type": "terminal", "name": "Claude", "command": "claude" }
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

## Full-Stack Dev

Use this when a repo needs terminals, browser preview, and persistent Dock
controls for repeated local development.

`.cmux/cmux.json`:

```json
{
  "commands": [
    {
      "name": "Full-Stack Dev",
      "workspace": {
        "name": "Dev",
        "cwd": ".",
        "layout": {
          "direction": "horizontal",
          "split": 0.55,
          "children": [
            {
              "direction": "vertical",
              "children": [
                {
                  "pane": {
                    "surfaces": [
                      { "type": "terminal", "name": "Web", "command": "bun dev" }
                    ]
                  }
                },
                {
                  "pane": {
                    "surfaces": [
                      { "type": "terminal", "name": "Tests", "command": "bun test --watch" }
                    ]
                  }
                }
              ]
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
    { "id": "git", "title": "Git", "command": "lazygit", "cwd": ".", "height": 320 },
    { "id": "feed", "title": "Feed", "command": "cmux feed tui --opentui", "height": 260 }
  ]
}
```

## SSH Devbox

Use this when the user's normal environment is remote, or when local cmux should
open a known SSH session beside project notes or a browser preview.

```json
{
  "commands": [
    {
      "name": "SSH Devbox",
      "keywords": ["ssh", "remote", "devbox"],
      "workspace": {
        "name": "Devbox",
        "cwd": ".",
        "layout": {
          "direction": "horizontal",
          "children": [
            {
              "pane": {
                "surfaces": [
                  { "type": "terminal", "name": "SSH", "command": "ssh devbox" }
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

## Review PR

Use this when a project needs one command to review a pull request with a
terminal, browser, and notes panel. Adjust the URL and command for the user's
GitHub workflow.

```json
{
  "commands": [
    {
      "name": "Review PR",
      "keywords": ["review", "pull request", "pr"],
      "workspace": {
        "name": "PR Review",
        "cwd": ".",
        "layout": {
          "direction": "horizontal",
          "children": [
            {
              "pane": {
                "surfaces": [
                  { "type": "terminal", "name": "GitHub", "command": "gh pr status" }
                ]
              }
            },
            {
              "pane": {
                "surfaces": [
                  { "type": "browser", "name": "Pull Request", "url": "https://github.com/owner/repo/pulls" }
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

## Docs Workspace

Use this when a repo needs one command for docs authoring with a dev server,
browser preview, and markdown viewer. Adjust the command, URL, and markdown path
for the docs stack.

```json
{
  "commands": [
    {
      "name": "Docs Workspace",
      "keywords": ["docs", "documentation", "preview"],
      "workspace": {
        "name": "Docs",
        "cwd": ".",
        "layout": {
          "direction": "horizontal",
          "split": 0.45,
          "children": [
            {
              "direction": "vertical",
              "children": [
                {
                  "pane": {
                    "surfaces": [
                      { "type": "terminal", "name": "Docs Server", "command": "bun run docs:dev" }
                    ]
                  }
                },
                {
                  "pane": {
                    "surfaces": [
                      {
                        "type": "terminal",
                        "name": "Markdown",
                        "command": "cmux markdown open docs/README.md --direction right --focus false; exec ${SHELL:-/bin/zsh} -l"
                      }
                    ]
                  }
                }
              ]
            },
            {
              "pane": {
                "surfaces": [
                  { "type": "browser", "name": "Docs Preview", "url": "http://localhost:3000/docs" }
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

## Quick Agent Buttons

Use this when the user wants tab bar buttons for common agents while keeping
the default new terminal and browser buttons.

```json
{
  "actions": {
    "codex-new-tab": {
      "type": "agent",
      "agent": "codex",
      "title": "Codex",
      "target": "newTabInCurrentPane",
      "palette": true
    },
    "claude-new-tab": {
      "type": "agent",
      "agent": "claude",
      "title": "Claude",
      "target": "newTabInCurrentPane",
      "palette": true
    }
  },
  "ui": {
    "surfaceTabBar": {
      "buttons": [
        "cmux.newTerminal",
        "cmux.newBrowser",
        { "action": "codex-new-tab", "title": "Codex" },
        { "action": "claude-new-tab", "title": "Claude" }
      ]
    }
  }
}
```

## CI Watch

Use this when the user wants a repeatable place for GitHub Actions, CircleCI,
or release-monitoring commands. Prefer Dock controls for long-running monitors.

`.cmux/dock.json`:

```json
{
  "controls": [
    {
      "id": "gh-runs",
      "title": "GitHub Runs",
      "command": "gh run list --limit 10 && exec ${SHELL:-/bin/zsh} -l",
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

## Validation Checklist

- Parse any changed JSON or JSONC before reporting success.
- Keep `cwd` inside the `workspace` object for workspace commands.
- Confirm `workspaceCommand.commandName` matches a `commands[].name`.
- Use `ui.newWorkspace.contextMenu` in new examples, not the alias.
- Keep built-in tab bar buttons only when the user wants them visible.
- Keep secrets out of config. Use shell profiles, env vars, or a secret store.
