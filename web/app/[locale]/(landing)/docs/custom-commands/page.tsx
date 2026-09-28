import type { ReactNode } from "react";
import { useTranslations } from "next-intl";
import { auditedDocsMetadata } from "../audited-docs-metadata";
import { DocsSchema } from "../docs-schema";
import { CodeBlock } from "@/app/[locale]/components/code-block";
import { Callout } from "@/app/[locale]/components/callout";
import { DocsHeading } from "@/app/[locale]/components/docs-heading";

type Chunks = ReactNode;
const code = (chunks: Chunks) => <code>{chunks}</code>;
const strong = (chunks: Chunks) => <strong>{chunks}</strong>;

/** Every listed tag renders as inline <code>. */
function codeTags<const K extends string>(...names: K[]): Record<K, (chunks: Chunks) => ReactNode> {
  return Object.fromEntries(names.map((name) => [name, code])) as Record<K, (chunks: Chunks) => ReactNode>;
}

/**
 * Some messages embed literal JSON (curly braces) inside tags, which ICU
 * formatting would try to parse as arguments. Split those on simple
 * `<tag>text</tag>` pairs ourselves and wrap each tagged run in <code>.
 */
function renderCodeTagged(message: string): ReactNode[] {
  return message
    .split(/<([A-Za-z][A-Za-z0-9]*)>(.*?)<\/\1>/g)
    .map((part, index) => {
      // split() with two capture groups yields [text, tag, body, text, tag, body, ...].
      const slot = index % 3;
      if (slot === 1) return null;
      return slot === 2 ? <code key={index}>{part}</code> : part;
    });
}

export async function generateMetadata({ params }: { params: Promise<{ locale: string }> }) {
  const { locale } = await params;
  return auditedDocsMetadata({
    locale,
    pageKey: "customCommands",
    path: "/docs/custom-commands",
  });
}

export default function CustomCommandsPage() {
  const t = useTranslations("docs.customCommands");

  return (
    <>
      <DocsSchema namespace="docs.customCommands" path="/docs/custom-commands" />
      <DocsHeading level={1} id="title">{t("title")}</DocsHeading>
      <p>{t("intro")}</p>

      <DocsHeading level={2} id="file-locations">{t("fileLocations")}</DocsHeading>
      <p>{t("fileLocationsDesc")}</p>
      <ul>
        <li><strong>{t("localConfig")}</strong> <code>./.cmux/cmux.json</code> ({t("localConfigDesc")})</li>
        <li><strong>{t("fallbackLocal")}</strong> <code>./cmux.json</code> ({t("fallbackLocalDesc")})</li>
        <li><strong>{t("globalConfig")}</strong> <code>~/.config/cmux/cmux.json</code> ({t("globalConfigDesc")})</li>
      </ul>
      <Callout type="info">{t("precedenceNote")}</Callout>
      <p>{t("liveReload")}</p>
      <Callout type="info">
        {t.rich("schemaErrorCallout", { title: strong })}
      </Callout>

      <DocsHeading level={2} id="simple-commands">{t("simpleCommands")}</DocsHeading>
      <p>{t("simpleCommandsDesc")}</p>
      <CodeBlock title="cmux.json" lang="json">{`{
  "commands": [
    {
      "name": "Format Changed Files",
      "description": "Run the formatter on files that differ from main",
      "keywords": [
        "fmt",
        "prettier",
        "style"
      ],
      "command": "git diff --name-only main -- '*.ts' '*.tsx' | xargs npx prettier --write"
    },
    {
      "name": "Reset Local Database",
      "keywords": [
        "db",
        "wipe"
      ],
      "command": "cd \\"$(git rev-parse --show-toplevel)\\" && ./scripts/db-reset.sh",
      "confirm": true
    }
  ]
}`}</CodeBlock>
      <DocsHeading level={3} id="simple-command-fields">{t("simpleCommandFields")}</DocsHeading>
      <ul>
        <li><code>name</code>: {t("fieldName")}</li>
        <li><code>command</code>: {t("fieldCommand")}</li>
        <li><code>description</code>: {t("fieldDescription")}</li>
        <li><code>keywords</code>: {t("fieldKeywords")}</li>
        <li><code>confirm</code>: {t("fieldConfirm")}</li>
      </ul>
      <p>
        {t("simpleCommandCwdNote")} <code>{`cd "$(git rev-parse --show-toplevel)" &&`}</code>{" "}
        {t("simpleCommandCwdRepoRoot")} <code>{"cd /some/folder &&"}</code> {t("simpleCommandCwdCustomPath")}
      </p>

      <DocsHeading level={2} id="workspace-commands">{t("workspaceCommands")}</DocsHeading>
      <p>{t("workspaceCommandsDesc")}</p>
      <CodeBlock title="cmux.json" lang="json">{`{
  "commands": [
    {
      "name": "API Stack",
      "keywords": [
        "api",
        "server",
        "logs"
      ],
      "restart": "confirm",
      "workspace": {
        "name": "API",
        "cwd": "./services/api",
        "color": "#10b981",
        "env": {
          "PORT": "8080"
        },
        "layout": {
          "direction": "vertical",
          "split": 0.65,
          "children": [
            {
              "direction": "horizontal",
              "children": [
                {
                  "pane": {
                    "surfaces": [
                      {
                        "type": "terminal",
                        "name": "Server",
                        "command": "go run ./cmd/api",
                        "focus": true
                      }
                    ]
                  }
                },
                {
                  "pane": {
                    "surfaces": [
                      {
                        "type": "terminal",
                        "name": "Worker",
                        "command": "go run ./cmd/worker",
                        "env": {
                          "QUEUE": "default"
                        }
                      }
                    ]
                  }
                }
              ]
            },
            {
              "pane": {
                "surfaces": [
                  {
                    "type": "terminal",
                    "name": "Logs",
                    "cwd": "/var/log",
                    "command": "tail -F system.log"
                  },
                  {
                    "type": "browser",
                    "name": "Health",
                    "url": "http://localhost:8080/healthz"
                  }
                ]
              }
            }
          ]
        }
      }
    }
  ]
}`}</CodeBlock>
      <DocsHeading level={3} id="workspace-fields">{t("workspaceFields")}</DocsHeading>
      <ul>
        <li><code>name</code>: {t("wsFieldName")}</li>
        <li><code>cwd</code>: {t("wsFieldCwd")}</li>
        <li><code>layout</code>: {t("wsFieldLayout")}</li>
        <li><code>color</code>: {t("wsFieldColor")}</li>
        <li><code>env</code>: {t("wsFieldEnv")}</li>
        <li><code>setup</code>: {t("wsFieldSetup")}</li>
      </ul>
      <DocsHeading level={3} id="restart-behavior">{t("restartBehavior")}</DocsHeading>
      <p>{t("restartBehaviorDesc")}</p>
      <ul>
        <li><code>&quot;new&quot;</code>: {t("restartNew")}</li>
        <li><code>&quot;confirm&quot;</code>: {t("restartConfirm")}</li>
        <li><code>&quot;recreate&quot;</code>: {t("restartRecreate")}</li>
        <li><code>&quot;ignore&quot;</code>: {t("restartIgnore")}</li>
      </ul>

      <DocsHeading level={2} id="layout-tree">{t("layoutTree")}</DocsHeading>
      <p>{t("layoutTreeDesc")}</p>
      <DocsHeading level={3} id="split-node">{t("splitNode")}</DocsHeading>
      <p>{t("splitNodeDesc")}</p>
      <ul>
        <li><code>direction</code>: <code>&quot;horizontal&quot;</code> {t("or")} <code>&quot;vertical&quot;</code></li>
        <li><code>children</code>: {t("splitChildren")}</li>
        <li><code>split</code>: {t("splitPosition")}</li>
      </ul>
      <DocsHeading level={3} id="pane-node">{t("paneNode")}</DocsHeading>
      <p>{t("paneNodeDesc")}</p>

      <DocsHeading level={2} id="surface-definition">{t("surfaceDefinition")}</DocsHeading>
      <p>{t("surfaceDefinitionDesc")}</p>
      <ul>
        <li><code>type</code>: <code>&quot;terminal&quot;</code> {t("or")} <code>&quot;browser&quot;</code></li>
        <li><code>name</code>: {t("surfaceName")}</li>
        <li><code>focus</code>: {t("surfaceFocus")}</li>
        <li><code>command</code>: {t("surfaceCommand")}</li>
        <li><code>url</code>: {t("surfaceUrl")}</li>
        <li><code>cwd</code>: {t("surfaceCwd")}</li>
        <li><code>env</code>: {t("surfaceEnv")}</li>
      </ul>
      <DocsHeading level={3} id="cwd-resolution">{t("cwdResolution")}</DocsHeading>
      <ul>
        <li><code>~/path</code>: {t("cwdHome")}</li>
        <li>{t("absolutePath")}: {t("cwdAbsolute")}</li>
        <li><code>./subdir</code>: {t("cwdSubdir")}</li>
        <li><code>.</code> {t("or")} {t("omitted")}: {t("cwdRelative")}</li>
      </ul>

      <DocsHeading level={2} id="schema">{t("schema")}</DocsHeading>
      <Callout type="info">
        {t.rich("nightlyFeatureCallout", codeTags("actions", "shortcut", "buttons"))}
      </Callout>
      <p>{t.rich("schemaIntro", codeTags("commands", "actions"))}</p>
      <CodeBlock title="cmux.json" lang="json">{`{
  "actions": {
    "cmux.newTerminal": {
      "type": "agent",
      "agent": "claude",
      "title": "Claude Code",
      "subtitle": "Start Claude Code in a new tab"
    },
    "lint": {
      "type": "command",
      "title": "Lint",
      "subtitle": "Run the linter in a fresh tab",
      "keywords": [
        "eslint",
        "check"
      ],
      "command": "npm run lint",
      "shortcut": [
        "cmd+k",
        "cmd+l"
      ],
      "icon": {
        "type": "symbol",
        "name": "checkmark.seal"
      }
    },
    "scratch-dir": {
      "type": "command",
      "title": "Scratch Directory",
      "command": "cd \\"$(mktemp -d)\\"",
      "target": "currentTerminal",
      "palette": false,
      "icon": {
        "type": "emoji",
        "value": "📝",
        "scale": 0.85
      }
    },
    "api-stack": {
      "type": "workspaceCommand",
      "title": "API Stack",
      "commandName": "API Stack"
    }
  },
  "ui": {
    "surfaceTabBar": {
      "buttons": [
        "cmux.newTerminal",
        "cmux.splitRight",
        "lint",
        {
          "action": "scratch-dir",
          "tooltip": "cd into a new temp folder"
        }
      ]
    }
  },
  "commands": [
    {
      "name": "API Stack",
      "keywords": [
        "api"
      ],
      "workspace": {
        "cwd": "./services/api",
        "layout": {
          "pane": {
            "surfaces": [
              {
                "type": "terminal",
                "name": "Server",
                "command": "go run ./cmd/api"
              }
            ]
          }
        }
      }
    }
  ]
}`}</CodeBlock>
      <DocsHeading level={3} id="nightly-action-registry">{t("nightlyActionRegistry")}</DocsHeading>
      <p>
        {t.rich(
          "nightlyActionRegistryDesc",
          codeTags("actions", "newTerminal", "newBrowser", "splitRight", "splitDown"),
        )}
      </p>
      <p>
        {t.rich(
          "paletteDesc",
          codeTags("palette", "trueValue", "falseValue", "shortcut", "singleShortcut", "chordShortcut"),
        )}
      </p>
      <p>{renderCodeTagged(t.raw("iconsDesc"))}</p>
      <p>{t("buttonEntriesDesc")}</p>
      <p>{t.rich("permissionFlagsDesc", codeTags("target"))}</p>
      <Callout type="info">{t("trustCallout")}</Callout>

      <DocsHeading level={2} id="custom-actions">{t("customActions")}</DocsHeading>
      <p>{t.rich("customActionsDesc", codeTags("actions", "commands", "palette"))}</p>
      <DocsHeading level={3} id="action-types">{t("actionTypes")}</DocsHeading>
      <ul>
        <li><code>&quot;command&quot;</code>: {t("actionTypeCommand")}</li>
        <li><code>&quot;agent&quot;</code>: {t("actionTypeAgent")}</li>
        <li><code>&quot;builtin&quot;</code>: {t("actionTypeBuiltin")} {t("actionTypeBuiltinCopy")} {t("actionTypeBuiltinCopyRemote")}</li>
        <li><code>&quot;workspaceCommand&quot;</code>: {t("actionTypeWorkspaceCommand")}</li>
        <li><code>&quot;workspace&quot;</code>: {t("actionTypeWorkspace")}</li>
      </ul>
      <DocsHeading level={3} id="action-fields">{t("actionFields")}</DocsHeading>
      <ul>
        <li><code>title</code>: {t("actionFieldTitle")}</li>
        <li><code>subtitle</code> / <code>description</code>: {t("actionFieldSubtitle")}</li>
        <li><code>keywords</code>: {t("actionFieldKeywords")}</li>
        <li><code>palette</code>: {t("actionFieldPalette")}</li>
        <li><code>shortcut</code>: {t("actionFieldShortcut")}</li>
        <li><code>target</code>: {t("actionFieldTarget")}</li>
        <li><code>confirm</code>: {t("actionFieldConfirm")}</li>
        <li><code>newWorkspaceMenu</code>: {t("actionFieldNewWorkspaceMenu")}</li>
      </ul>
      <DocsHeading level={3} id="command-palette-behavior">{t("commandPaletteBehavior")}</DocsHeading>
      <p>
        {t.rich("commandPaletteBehaviorDesc", codeTags("palette", "commands", "newTerminal"))}
      </p>

      <DocsHeading level={2} id="new-workspace-button">{t("newWorkspaceButton")}</DocsHeading>
      <p>{renderCodeTagged(t.raw("newWorkspaceButtonDesc"))}</p>
      <CodeBlock title="cmux.json" lang="json">{`{
  "actions": {
    "worktree-agents": {
      "type": "workspaceCommand",
      "title": "Agents in New Worktree",
      "commandName": "Agents in New Worktree",
      "icon": {
        "type": "symbol",
        "name": "arrow.triangle.branch"
      }
    }
  },
  "ui": {
    "newWorkspace": {
      "action": "worktree-agents",
      "contextMenu": [
        "worktree-agents",
        {
          "type": "separator"
        },
        {
          "action": "cmux.newWorkspace",
          "title": "Blank Workspace"
        },
        {
          "action": "cmux.newBrowser",
          "title": "Browser"
        }
      ]
    }
  },
  "commands": [
    {
      "name": "Agents in New Worktree",
      "description": "Branch off a new Git worktree, then run Codex and Claude Code in it side by side",
      "workspace": {
        "name": "Worktree",
        "layout": {
          "direction": "vertical",
          "split": 0.7,
          "children": [
            {
              "direction": "horizontal",
              "children": [
                {
                  "pane": {
                    "surfaces": [
                      {
                        "type": "terminal",
                        "name": "Codex",
                        "command": "marker=\\"\${TMPDIR:-/tmp}/cmux-wt-\${CMUX_WORKSPACE_ID:-local}\\"; echo \\"Waiting for the worktree...\\"; until [ -s \\"$marker\\" ]; do sleep 0.25; done; cd \\"$(cat \\"$marker\\")\\" && exec codex --yolo"
                      }
                    ]
                  }
                },
                {
                  "pane": {
                    "surfaces": [
                      {
                        "type": "terminal",
                        "name": "Claude",
                        "command": "marker=\\"\${TMPDIR:-/tmp}/cmux-wt-\${CMUX_WORKSPACE_ID:-local}\\"; echo \\"Waiting for the worktree...\\"; until [ -s \\"$marker\\" ]; do sleep 0.25; done; cd \\"$(cat \\"$marker\\")\\" && exec claude --dangerously-skip-permissions"
                      }
                    ]
                  }
                }
              ]
            },
            {
              "pane": {
                "surfaces": [
                  {
                    "type": "terminal",
                    "name": "Setup",
                    "command": "marker=\\"\${TMPDIR:-/tmp}/cmux-wt-\${CMUX_WORKSPACE_ID:-local}\\"; rm -f \\"$marker\\"; root=$(git rev-parse --show-toplevel) || exit 1; branch=\\"wt-$(date +%m%d-%H%M%S)\\"; wt=\\"$root/../$(basename \\"$root\\")-$branch\\"; git -C \\"$root\\" worktree add -b \\"$branch\\" \\"$wt\\" && printf \\"%s\\\\n\\" \\"$wt\\" > \\"$marker\\" && cd \\"$wt\\" && exec \\"\${SHELL:-/bin/zsh}\\" -l",
                    "focus": true
                  }
                ]
              }
            }
          ]
        }
      }
    }
  ]
}`}</CodeBlock>
      <p>
        {t.rich("newWorkspaceWorktreeNote", codeTags("action", "commands", "worktree", "codex"))}
      </p>

      <DocsHeading level={2} id="workspace-layouts">{t("workspaceActions")}</DocsHeading>
      <p>{t.rich("workspaceActionsDesc", codeTags("workspace", "commands", "setup"))}</p>
      <CodeBlock title="cmux.json" lang="json">{`{
  "actions": {
    "pair-review": {
      "type": "workspace",
      "title": "Pair Review",
      "icon": {
        "type": "symbol",
        "name": "person.2.wave.2"
      },
      "restart": "ignore",
      "newWorkspaceMenu": true,
      "workspace": {
        "name": "Review",
        "cwd": "~/src/app",
        "setup": "git pull --ff-only",
        "layout": {
          "direction": "horizontal",
          "split": 0.55,
          "children": [
            {
              "pane": {
                "surfaces": [
                  {
                    "type": "terminal",
                    "name": "Diff",
                    "command": "git log -p -n 5",
                    "focus": true
                  }
                ]
              }
            },
            {
              "pane": {
                "surfaces": [
                  {
                    "type": "terminal",
                    "name": "Codex",
                    "command": "codex"
                  },
                  {
                    "type": "terminal",
                    "name": "Shell"
                  }
                ]
              }
            }
          ]
        }
      }
    }
  }
}`}</CodeBlock>
      <p>
        {t.rich("workspaceActionsMenuDesc", codeTags("newWorkspaceMenu", "falseValue", "trueValue"))}
      </p>
      <p>
        {t.rich("workspaceActionsSaveDesc", {
          saveLayout: strong,
          customize: strong,
          ...codeTags("configPath", "actions"),
        })}
      </p>
      <DocsHeading level={3} id="default-workspace-layout">{t("workspaceActionsDefaultTitle")}</DocsHeading>
      <p>
        {t.rich("workspaceActionsDefaultDesc", {
          defaultMenu: strong,
          checkbox: strong,
          ...codeTags("action", "localConfig", "globalConfig"),
        })}
      </p>

      <DocsHeading level={2} id="full-example">{t("fullExample")}</DocsHeading>
      <CodeBlock title="cmux.json" lang="json">{`{
  "actions": {
    "cmux.newTerminal": {
      "type": "command",
      "title": "Codex",
      "command": "codex --yolo",
      "shortcut": "cmd+t",
      "icon": {
        "type": "image",
        "path": "./icons/codex.svg"
      }
    },
    "review": {
      "type": "agent",
      "agent": "claude",
      "args": "--permission-mode plan",
      "title": "Plan with Claude",
      "shortcut": "cmd+shift+p",
      "icon": {
        "type": "symbol",
        "name": "list.bullet.clipboard"
      }
    },
    "storybook": {
      "type": "workspaceCommand",
      "commandName": "Storybook",
      "newWorkspaceMenu": true
    },
    "typecheck": {
      "type": "command",
      "title": "Typecheck",
      "command": "npx tsc --noEmit",
      "target": "newTabInCurrentPane",
      "confirm": false,
      "icon": {
        "type": "emoji",
        "value": "🔎"
      }
    }
  },
  "ui": {
    "surfaceTabBar": {
      "buttons": [
        "cmux.newTerminal",
        "review",
        {
          "action": "typecheck",
          "title": "tsc"
        },
        "cmux.newBrowser",
        "cmux.splitDown"
      ]
    },
    "newWorkspace": {
      "contextMenu": [
        "storybook",
        {
          "type": "separator"
        },
        "cmux.newTerminal",
        "cmux.newBrowser"
      ]
    }
  },
  "commands": [
    {
      "name": "Storybook",
      "description": "Component explorer with a live preview beside it",
      "keywords": [
        "ui",
        "components",
        "stories"
      ],
      "workspace": {
        "name": "Storybook",
        "cwd": "./packages/ui",
        "color": "#a855f7",
        "layout": {
          "direction": "horizontal",
          "split": 0.4,
          "children": [
            {
              "direction": "vertical",
              "split": 0.5,
              "children": [
                {
                  "pane": {
                    "surfaces": [
                      {
                        "type": "terminal",
                        "name": "Storybook",
                        "command": "npx storybook dev -p 6006 --no-open",
                        "focus": true
                      }
                    ]
                  }
                },
                {
                  "pane": {
                    "surfaces": [
                      {
                        "type": "terminal",
                        "name": "Tests",
                        "command": "npx vitest --watch",
                        "env": {
                          "CI": "false"
                        }
                      }
                    ]
                  }
                }
              ]
            },
            {
              "pane": {
                "surfaces": [
                  {
                    "type": "browser",
                    "name": "Preview",
                    "url": "http://localhost:6006"
                  }
                ]
              }
            }
          ]
        }
      }
    },
    {
      "name": "Install Dependencies",
      "keywords": [
        "install",
        "deps"
      ],
      "command": "npm ci",
      "confirm": true
    },
    {
      "name": "Open Changelog",
      "keywords": [
        "changes",
        "release"
      ],
      "command": "\${EDITOR:-vi} CHANGELOG.md"
    }
  ]
}`}</CodeBlock>
    </>
  );
}
