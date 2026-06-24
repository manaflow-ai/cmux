import { useTranslations } from "next-intl";
import { getTranslations } from "next-intl/server";
import { buildAlternates } from "../../../../i18n/seo";
import { DocsSchema } from "../docs-schema";
import { CodeBlock } from "../../components/code-block";
import { Callout } from "../../components/callout";
import { DocsHeading } from "../../components/docs-heading";

export async function generateMetadata({ params }: { params: Promise<{ locale: string }> }) {
  const { locale } = await params;
  const t = await getTranslations({ locale, namespace: "docs.notifications" });
  return {
    title: t("metaTitle"),
    description: t("metaDescription"),
    alternates: buildAlternates(locale, "/docs/notifications"),
  };
}

export default function NotificationsPage() {
  const t = useTranslations("docs.notifications");

  return (
    <>
      <DocsSchema namespace="docs.notifications" path="/docs/notifications" />
      <DocsHeading level={1} id="title">{t("title")}</DocsHeading>
      <p>{t("intro")}</p>

      <DocsHeading level={2} id="lifecycle">{t("lifecycle")}</DocsHeading>
      <ol>
        <li>{t("received")}</li>
        <li>{t("unread")}</li>
        <li>{t("read")}</li>
        <li>{t("cleared")}</li>
      </ol>

      <DocsHeading level={3} id="suppression">{t("suppression")}</DocsHeading>
      <p>{t("suppressionDesc")}</p>
      <ul>
        <li>{t("suppressItem1")}</li>
        <li>{t("suppressItem2")}</li>
        <li>{t("suppressItem3")}</li>
      </ul>

      <DocsHeading level={3} id="notification-panel">{t("notificationPanel")}</DocsHeading>
      <p>
        {t.rich("notificationPanelDesc", {
          openShortcut: (chunks) => <code>{chunks}</code>,
          jumpShortcut: (chunks) => <code>{chunks}</code>,
        })}
      </p>

      <DocsHeading level={2} id="custom-command">{t("customCommand")}</DocsHeading>
      <p>{t("customCommandDesc")}</p>
      <table>
        <thead>
          <tr>
            <th>{t("variableHeader")}</th>
            <th>{t("descriptionHeader")}</th>
          </tr>
        </thead>
        <tbody>
          <tr>
            <td><code>CMUX_NOTIFICATION_TITLE</code></td>
            <td>{t("envTitle")}</td>
          </tr>
          <tr>
            <td><code>CMUX_NOTIFICATION_SUBTITLE</code></td>
            <td>{t("envSubtitle")}</td>
          </tr>
          <tr>
            <td><code>CMUX_NOTIFICATION_BODY</code></td>
            <td>{t("envBody")}</td>
          </tr>
        </tbody>
      </table>
      <CodeBlock title="Examples" lang="bash">{`# Text-to-speech
say "$CMUX_NOTIFICATION_TITLE"

# Custom sound file
afplay /path/to/sound.aiff

# Log to file
echo "$CMUX_NOTIFICATION_TITLE: $CMUX_NOTIFICATION_BODY" >> ~/notifications.log`}</CodeBlock>
      <p>{t("customCommandNote")}</p>

      <DocsHeading level={2} id="notification-hooks">{t("hooksTitle")}</DocsHeading>
      <p>
        {t.rich("hooksIntro", {
          config: (chunks) => <code>{chunks}</code>,
          hooksMode: (chunks) => <code>{chunks}</code>,
        })}
      </p>
      <CodeBlock title={t("hooksJsonTitle")} lang="json">{`{
  "notifications": {
    "hooks": [
      {
        "id": "quiet-docs",
        "command": "sed 's/\"desktop\":true/\"desktop\":false/'",
        "timeoutSeconds": 20
      }
    ]
  }
}`}</CodeBlock>
      <CodeBlock title={t("hooksIOTitle")} lang="json">{`{
  "version": 1,
  "notification": {
    "workspaceId": "3B3F0D83-...",
    "surfaceId": "7E9C1A02-...",
    "title": "Codex",
    "subtitle": "Waiting",
    "body": "Agent needs input"
  },
  "context": {
    "cwd": "/path/to/project",
    "configPath": "/path/to/project/.cmux/cmux.json",
    "hookId": "quiet-docs",
    "appFocused": false,
    "focusedPanel": false
  },
  "effects": {
    "record": true,
    "markUnread": true,
    "reorderWorkspace": true,
    "desktop": true,
    "sound": true,
    "command": true,
    "paneFlash": true
  }
}`}</CodeBlock>
      <p>
        {t.rich("hooksDetails", {
          globalConfig: (chunks) => <code>{chunks}</code>,
          projectConfig: (chunks) => <code>{chunks}</code>,
          config: (chunks) => <code>{chunks}</code>,
          desktop: (chunks) => <code>{chunks}</code>,
          hooksMode: (chunks) => <code>{chunks}</code>,
          replace: (chunks) => <code>{chunks}</code>,
        })}
      </p>

      <DocsHeading level={2} id="sending">{t("sending")}</DocsHeading>

      <DocsHeading level={3} id="cli-usage">{t("cli")}</DocsHeading>
      <CodeBlock lang="bash">{`cmux notify --title "Task Complete" --body "Your build finished"
cmux notify --title "Claude Code" --subtitle "Waiting" --body "Agent needs input"`}</CodeBlock>

      <DocsHeading level={3} id="osc777-title">{t("osc777Title")}</DocsHeading>
      <p>{t("osc777Desc")}</p>
      <CodeBlock lang="bash">{`printf '\\e]777;notify;My Title;Message body here\\a'`}</CodeBlock>
      <CodeBlock title="Shell function" lang="bash">{`notify_osc777() {
    local title="$1"
    local body="$2"
    printf '\\e]777;notify;%s;%s\\a' "$title" "$body"
}

notify_osc777 "Build Complete" "All tests passed"`}</CodeBlock>

      <DocsHeading level={3} id="osc99-title">{t("osc99Title")}</DocsHeading>
      <p>{t("osc99Desc")}</p>
      <CodeBlock lang="bash">{`# Format: ESC ] 99 ; <params> ; <payload> ESC \\

# Simple notification
printf '\\e]99;i=1;e=1;d=0:Hello World\\e\\\\'

# With title, subtitle, and body
printf '\\e]99;i=1;e=1;d=0;p=title:Build Complete\\e\\\\'
printf '\\e]99;i=1;e=1;d=0;p=subtitle:Project X\\e\\\\'
printf '\\e]99;i=1;e=1;d=1;p=body:All tests passed\\e\\\\'`}</CodeBlock>

      <table>
        <thead>
          <tr>
            <th>{t("featureHeader")}</th>
            <th>OSC 99</th>
            <th>OSC 777</th>
          </tr>
        </thead>
        <tbody>
          <tr>
            <td>{t("cmpTitleBody")}</td>
            <td>{t("cmpYes")}</td>
            <td>{t("cmpYes")}</td>
          </tr>
          <tr>
            <td>{t("cmpSubtitle")}</td>
            <td>{t("cmpYes")}</td>
            <td>{t("cmpNo")}</td>
          </tr>
          <tr>
            <td>{t("cmpNotificationId")}</td>
            <td>{t("cmpYes")}</td>
            <td>{t("cmpNo")}</td>
          </tr>
          <tr>
            <td>{t("cmpComplexity")}</td>
            <td>{t("cmpHigher")}</td>
            <td>{t("cmpLower")}</td>
          </tr>
        </tbody>
      </table>

      <Callout>
        {t("comparisonCallout")}
      </Callout>

      <DocsHeading level={2} id="claude-code-hooks">{t("claudeCodeHooks")}</DocsHeading>
      <p>
        {t.rich("claudeCodeHooksDesc", {
          link: (chunks) => (
            <a href="https://docs.anthropic.com/en/docs/claude-code">{chunks}</a>
          ),
        })}
      </p>

      <DocsHeading level={3} id="create-hook-script">{t("createHookScript")}</DocsHeading>
      <CodeBlock title="~/.claude/hooks/cmux-notify.sh" lang="bash">{`#!/bin/bash
# Skip if not in cmux
[ -S /tmp/cmux.sock ] || exit 0

EVENT=$(cat)
EVENT_TYPE=$(echo "$EVENT" | jq -r '.hook_event_name // "unknown"')
TOOL=$(echo "$EVENT" | jq -r '.tool_name // ""')

case "$EVENT_TYPE" in
    "Stop")
        cmux notify --title "Claude Code" --body "Session complete"
        ;;
    "PostToolUse")
        [ "$TOOL" = "Task" ] && cmux notify --title "Claude Code" --body "Agent finished"
        ;;
esac`}</CodeBlock>
      <CodeBlock lang="bash">{`chmod +x ~/.claude/hooks/cmux-notify.sh`}</CodeBlock>

      <DocsHeading level={3} id="configure-claude">{t("configureClaude")}</DocsHeading>
      <CodeBlock title="~/.claude/settings.json" lang="json">{`{
  "hooks": {
    "Stop": [
      {
        "matcher": "",
        "hooks": [
          {
            "type": "command",
            "command": "~/.claude/hooks/cmux-notify.sh"
          }
        ]
      }
    ],
    "PostToolUse": [
      {
        "matcher": "Task",
        "hooks": [
          {
            "type": "command",
            "command": "~/.claude/hooks/cmux-notify.sh"
          }
        ]
      }
    ]
  }
}`}</CodeBlock>
      <p>{t("restartNote")}</p>

      <DocsHeading level={2} id="copilot-cli-hooks">{t("copilotCliHooks")}</DocsHeading>
      <p>
        {t.rich("copilotCliHooksDesc", {
          link: (chunks) => (
            <a href="https://docs.github.com/en/copilot/how-tos/use-copilot-agents/coding-agent/use-hooks">{chunks}</a>
          ),
        })}
      </p>
      <CodeBlock title="~/.copilot/config.json" lang="json">{`{
  "hooks": {
    "userPromptSubmitted": [
      {
        "type": "command",
        "bash": "if command -v cmux &>/dev/null; then cmux set-status copilot_cli Running; fi",
        "timeoutSec": 3
      }
    ],
    "agentStop": [
      {
        "type": "command",
        "bash": "if command -v cmux &>/dev/null; then cmux notify --title 'Copilot CLI' --body 'Done'; cmux set-status copilot_cli Idle; fi",
        "timeoutSec": 5
      }
    ],
    "errorOccurred": [
      {
        "type": "command",
        "bash": "if command -v cmux &>/dev/null; then cmux notify --title 'Copilot CLI' --subtitle 'Error' --body 'An error occurred'; cmux set-status copilot_cli Error; fi",
        "timeoutSec": 5
      }
    ],
    "sessionEnd": [
      {
        "type": "command",
        "bash": "if command -v cmux &>/dev/null; then cmux clear-status copilot_cli; fi",
        "timeoutSec": 3
      }
    ]
  }
}`}</CodeBlock>
      <p>{t("copilotCliRepoHooks")}</p>
      <CodeBlock title=".github/hooks/notify.json" lang="json">{`{
  "version": 1,
  "hooks": {
    "userPromptSubmitted": [ ... ],
    "agentStop": [ ... ]
  }
}`}</CodeBlock>

      <DocsHeading level={2} id="integration-examples">{t("integrationExamples")}</DocsHeading>

      <DocsHeading level={3} id="notify-after-long">{t("notifyAfterLong")}</DocsHeading>
      <CodeBlock title="~/.zshrc" lang="bash">{`# Add to your shell config
notify-after() {
  "$@"
  local exit_code=$?
  if [ $exit_code -eq 0 ]; then
    cmux notify --title "✓ Command Complete" --body "$1"
  else
    cmux notify --title "✗ Command Failed" --body "$1 (exit $exit_code)"
  fi
  return $exit_code
}

# Usage: notify-after npm run build`}</CodeBlock>

      <DocsHeading level={3} id="python">{t("python")}</DocsHeading>
      <CodeBlock title="python" lang="python">{`import sys

def notify(title: str, body: str):
    """Send OSC 777 notification."""
    sys.stdout.write(f'\\x1b]777;notify;{title};{body}\\x07')
    sys.stdout.flush()

notify("Script Complete", "Processing finished")`}</CodeBlock>

      <DocsHeading level={3} id="nodejs">{t("nodejs")}</DocsHeading>
      <CodeBlock title="node" lang="javascript">{`function notify(title, body) {
  process.stdout.write(\`\\x1b]777;notify;\${title};\${body}\\x07\`);
}

notify('Build Done', 'webpack finished');`}</CodeBlock>

      <DocsHeading level={3} id="tmux-passthrough">{t("tmuxPassthrough")}</DocsHeading>
      <p>{t("tmuxDesc")}</p>
      <CodeBlock title=".tmux.conf" lang="bash">{`set -g allow-passthrough on`}</CodeBlock>
      <CodeBlock lang="bash">{`printf '\\ePtmux;\\e\\e]777;notify;Title;Body\\a\\e\\\\'`}</CodeBlock>
    </>
  );
}
