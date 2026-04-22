import { useTranslations } from "next-intl";
import { getTranslations } from "next-intl/server";
import { buildAlternates } from "../../../../i18n/seo";
import { CodeBlock } from "../../components/code-block";
import { Callout } from "../../components/callout";

export async function generateMetadata({ params }: { params: Promise<{ locale: string }> }) {
  const { locale } = await params;
  const t = await getTranslations({ locale, namespace: "docs.customCommands" });
  return {
    title: t("metaTitle"),
    description: t("metaDescription"),
    alternates: buildAlternates(locale, "/docs/custom-commands"),
  };
}

export default function CustomCommandsPage() {
  const t = useTranslations("docs.customCommands");

  return (
    <>
      <h1>{t("title")}</h1>
      <p>{t("intro")}</p>

      <h2>{t("fileLocations")}</h2>
      <p>{t("fileLocationsDesc")}</p>
      <ul>
        <li>
          <strong>{t("localConfig")}</strong> <code>./cmux.json</code> &mdash; {t("localConfigDesc")}
        </li>
        <li>
          <strong>{t("globalConfig")}</strong> <code>~/.config/cmux/cmux.json</code> &mdash; {t("globalConfigDesc")}
        </li>
      </ul>
      <Callout type="info">{t("precedenceNote")}</Callout>
      <Callout type="info">
        Custom action buttons are a nightly feature. Install the latest nightly build before using the
        <code>actions</code> and <code>ui</code> fields below.
      </Callout>
      <p>{t("liveReload")}</p>

      <h2>{t("schema")}</h2>
      <p>{t("schemaDesc")}</p>
      <p>
        Nightly builds also support an <code>actions</code> registry and <code>ui</code> placements for
        the new-workspace button and the surface tab bar.
      </p>
      <CodeBlock title="cmux.json" lang="json">{`{
  "actions": {
    "new-dev": { "type": "workspaceCommand", "commandName": "Start Dev" },
    "start-codex": { "type": "agent", "agent": "codex" },
    "start-claude": { "type": "agent", "agent": "claude" },
    "run-tests": { "type": "command", "command": "npm test", "confirm": true }
  },
  "ui": {
    "newWorkspace": { "action": "new-dev" },
    "surfaceTabBar": {
      "buttons": [
        { "action": "newTerminal", "icon": "terminal", "tooltip": "New terminal" },
        { "action": "newBrowser", "icon": "globe", "tooltip": "New browser" },
        { "action": "start-codex", "icon": { "type": "image", "path": "./icons/codex.png" }, "tooltip": "Start Codex" },
        { "action": "start-claude", "icon": { "type": "image", "path": "./icons/claude.jpg" }, "tooltip": "Start Claude Code" },
        { "action": "run-tests", "icon": { "type": "emoji", "value": "✅" }, "tooltip": "Run tests" }
      ]
    }
  },
  "commands": [
    {
      "name": "Start Dev",
      "keywords": ["dev", "start"],
      "workspace": { ... }
    },
    {
      "name": "Run Tests",
      "command": "npm test",
      "confirm": true
    }
  ]
}`}</CodeBlock>
      <h3>Nightly action buttons</h3>
      <p>
        <code>ui.surfaceTabBar.buttons</code> replaces the default buttons when present, so omit built-ins
        like <code>newTerminal</code>, <code>newBrowser</code>, <code>splitRight</code>, or <code>splitDown</code>
        to hide them. Button icons accept macOS SF Symbol names, emoji, or image paths relative to the
        <code>cmux.json</code> file. PNG, JPEG, GIF, TIFF, HEIC, WebP, and ICNS files are supported.
      </p>
      <CodeBlock title="cmux.json" lang="json">{`{
  "actions": {
    "start-codex": { "type": "agent", "agent": "codex" },
    "start-claude": { "type": "agent", "agent": "claude", "args": "--permission-mode acceptEdits" }
  },
  "ui": {
    "surfaceTabBar": {
      "buttons": [
        { "id": "codex-symbol", "action": "start-codex", "icon": "sparkles", "tooltip": "Start Codex" },
        { "id": "claude-emoji", "action": "start-claude", "icon": "emoji:🤖", "tooltip": "Start Claude Code" },
        { "id": "codex-png", "action": "start-codex", "icon": "./icons/codex.png", "tooltip": "Start Codex with a PNG icon" },
        { "id": "claude-jpeg", "action": "start-claude", "icon": { "type": "image", "path": "./icons/claude.jpeg" } }
      ]
    }
  }
}`}</CodeBlock>

      <h2>{t("simpleCommands")}</h2>
      <p>{t("simpleCommandsDesc")}</p>
      <CodeBlock title="cmux.json" lang="json">{`{
  "commands": [
    {
      "name": "Run Tests",
      "keywords": ["test", "check"],
      "command": "npm test",
      "confirm": true
    }
  ]
}`}</CodeBlock>

      <h3>{t("simpleCommandFields")}</h3>
      <ul>
        <li><code>name</code> &mdash; {t("fieldName")}</li>
        <li><code>description</code> &mdash; {t("fieldDescription")}</li>
        <li><code>keywords</code> &mdash; {t("fieldKeywords")}</li>
        <li><code>command</code> &mdash; {t("fieldCommand")}</li>
        <li><code>confirm</code> &mdash; {t("fieldConfirm")}</li>
      </ul>
      <p>{t("simpleCommandCwdNote")} <code>{"cd \"$(git rev-parse --show-toplevel)\" &&"}</code> {t("simpleCommandCwdRepoRoot")} <code>{"cd /your/path &&"}</code> {t("simpleCommandCwdCustomPath")}</p>

      <h2>{t("workspaceCommands")}</h2>
      <p>{t("workspaceCommandsDesc")}</p>
      <CodeBlock title="cmux.json" lang="json">{`{
  "commands": [
    {
      "name": "Dev Environment",
      "keywords": ["dev", "fullstack"],
      "restart": "confirm",
      "workspace": {
        "name": "Dev",
        "cwd": ".",
        "layout": {
          "direction": "horizontal",
          "split": 0.5,
          "children": [
            {
              "pane": {
                "surfaces": [
                  {
                    "type": "terminal",
                    "name": "Frontend",
                    "command": "npm run dev",
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
                    "name": "Backend",
                    "command": "cargo watch -x run",
                    "cwd": "./server",
                    "env": { "RUST_LOG": "debug" }
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

      <h3>{t("workspaceFields")}</h3>
      <ul>
        <li><code>name</code> &mdash; {t("wsFieldName")}</li>
        <li><code>cwd</code> &mdash; {t("wsFieldCwd")}</li>
        <li><code>color</code> &mdash; {t("wsFieldColor")}</li>
        <li><code>layout</code> &mdash; {t("wsFieldLayout")}</li>
      </ul>

      <h3>{t("restartBehavior")}</h3>
      <p>{t("restartBehaviorDesc")}</p>
      <ul>
        <li><code>&quot;ignore&quot;</code> &mdash; {t("restartIgnore")}</li>
        <li><code>&quot;recreate&quot;</code> &mdash; {t("restartRecreate")}</li>
        <li><code>&quot;confirm&quot;</code> &mdash; {t("restartConfirm")}</li>
      </ul>

      <h2>{t("layoutTree")}</h2>
      <p>{t("layoutTreeDesc")}</p>

      <h3>{t("splitNode")}</h3>
      <p>{t("splitNodeDesc")}</p>
      <ul>
        <li><code>direction</code> &mdash; <code>&quot;horizontal&quot;</code> {t("or")} <code>&quot;vertical&quot;</code></li>
        <li><code>split</code> &mdash; {t("splitPosition")}</li>
        <li><code>children</code> &mdash; {t("splitChildren")}</li>
      </ul>

      <h3>{t("paneNode")}</h3>
      <p>{t("paneNodeDesc")}</p>

      <h2>{t("surfaceDefinition")}</h2>
      <p>{t("surfaceDefinitionDesc")}</p>
      <ul>
        <li><code>type</code> &mdash; <code>&quot;terminal&quot;</code> {t("or")} <code>&quot;browser&quot;</code></li>
        <li><code>name</code> &mdash; {t("surfaceName")}</li>
        <li><code>command</code> &mdash; {t("surfaceCommand")}</li>
        <li><code>cwd</code> &mdash; {t("surfaceCwd")}</li>
        <li><code>env</code> &mdash; {t("surfaceEnv")}</li>
        <li><code>url</code> &mdash; {t("surfaceUrl")}</li>
        <li><code>focus</code> &mdash; {t("surfaceFocus")}</li>
      </ul>

      <h3>{t("cwdResolution")}</h3>
      <ul>
        <li><code>.</code> {t("or")} {t("omitted")} &mdash; {t("cwdRelative")}</li>
        <li><code>./subdir</code> &mdash; {t("cwdSubdir")}</li>
        <li><code>~/path</code> &mdash; {t("cwdHome")}</li>
        <li>{t("absolutePath")} &mdash; {t("cwdAbsolute")}</li>
      </ul>

      <h2>{t("fullExample")}</h2>
      <CodeBlock title="cmux.json" lang="json">{`{
  "actions": {
    "new-web-dev": { "type": "workspaceCommand", "commandName": "Web Dev" },
    "start-dev": { "type": "command", "command": "npm run dev" },
    "start-codex": { "type": "agent", "agent": "codex" },
    "start-claude": { "type": "agent", "agent": "claude" }
  },
  "ui": {
    "newWorkspace": { "action": "new-web-dev" },
    "surfaceTabBar": {
      "buttons": [
        { "action": "start-dev", "icon": "play.circle", "tooltip": "Start dev" },
        { "action": "newBrowser", "icon": "globe", "tooltip": "New browser" },
        { "action": "start-codex", "icon": "./icons/codex.png", "tooltip": "Start Codex" },
        { "action": "start-claude", "icon": "emoji:🤖", "tooltip": "Start Claude Code" }
      ]
    }
  },
  "commands": [
    {
      "name": "Web Dev",
      "description": "Docs site with live preview",
      "keywords": ["web", "docs", "next", "frontend"],
      "restart": "confirm",
      "workspace": {
        "name": "Web Dev",
        "cwd": "./web",
        "color": "#3b82f6",
        "layout": {
          "direction": "horizontal",
          "split": 0.5,
          "children": [
            {
              "pane": {
                "surfaces": [
                  {
                    "type": "terminal",
                    "name": "Next.js",
                    "command": "npm run dev",
                    "focus": true
                  }
                ]
              }
            },
            {
              "direction": "vertical",
              "split": 0.6,
              "children": [
                {
                  "pane": {
                    "surfaces": [
                      {
                        "type": "browser",
                        "name": "Preview",
                        "url": "http://localhost:3777"
                      }
                    ]
                  }
                },
                {
                  "pane": {
                    "surfaces": [
                      {
                        "type": "terminal",
                        "name": "Shell",
                        "env": { "NODE_ENV": "development" }
                      }
                    ]
                  }
                }
              ]
            }
          ]
        }
      }
    },
    {
      "name": "Debug Log",
      "description": "Tail the debug event log from the running dev app",
      "keywords": ["log", "debug", "tail", "events"],
      "restart": "ignore",
      "workspace": {
        "name": "Debug Log",
        "layout": {
          "direction": "horizontal",
          "split": 0.5,
          "children": [
            {
              "pane": {
                "surfaces": [
                  {
                    "type": "terminal",
                    "name": "Events",
                    "command": "tail -f /tmp/cmux-debug.log",
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
                    "name": "Shell"
                  }
                ]
              }
            }
          ]
        }
      }
    },
    {
      "name": "Setup",
      "description": "Initialize submodules and build dependencies",
      "keywords": ["setup", "init", "install"],
      "command": "./scripts/setup.sh",
      "confirm": true
    },
    {
      "name": "Reload",
      "description": "Build and launch the debug app tagged to the current branch",
      "keywords": ["reload", "build", "run", "launch"],
      "command": "./scripts/reload.sh --tag $(git branch --show-current)"
    },
    {
      "name": "Run Unit Tests",
      "keywords": ["test", "unit"],
      "command": "./scripts/test-unit.sh",
      "confirm": true
    }
  ]
}`}</CodeBlock>
    </>
  );
}
