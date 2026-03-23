import { useTranslations } from "next-intl";
import { getTranslations } from "next-intl/server";
import { CodeBlock } from "../../components/code-block";
import { Callout } from "../../components/callout";

export async function generateMetadata({ params }: { params: Promise<{ locale: string }> }) {
  const { locale } = await params;
  const t = await getTranslations({ locale, namespace: "docs.notifications" });
  return {
    title: t("metaTitle"),
    description: t("metaDescription"),
  };
}

export default function NotificationsPage() {
  const t = useTranslations("docs.notifications");

  return (
    <>
      <h1>{t("title")}</h1>
      <p>{t("intro")}</p>

      <h2>{t("lifecycle")}</h2>
      <ol>
        <li>{t("received")}</li>
        <li>{t("unread")}</li>
        <li>{t("read")}</li>
        <li>{t("cleared")}</li>
      </ol>

      <h3>{t("suppression")}</h3>
      <p>{t("suppressionDesc")}</p>
      <ul>
        <li>{t("suppressItem1")}</li>
        <li>{t("suppressItem2")}</li>
        <li>{t("suppressItem3")}</li>
      </ul>

      <h3>{t("notificationPanel")}</h3>
      <p>
        {t.rich("notificationPanelDesc", {
          openShortcut: (chunks) => <code>{chunks}</code>,
          jumpShortcut: (chunks) => <code>{chunks}</code>,
        })}
      </p>

      <h2>{t("customCommand")}</h2>
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

      <h2>{t("sending")}</h2>

      <h3>{t("cli")}</h3>
      <CodeBlock lang="bash">{`cmux notify --title "Task Complete" --body "Your build finished"
cmux notify --title "Claude Code" --subtitle "Waiting" --body "Agent needs input"`}</CodeBlock>

      <h3>{t("osc777Title")}</h3>
      <p>{t("osc777Desc")}</p>
      <CodeBlock lang="bash">{`printf '\\e]777;notify;My Title;Message body here\\a'`}</CodeBlock>
      <CodeBlock title="Shell function" lang="bash">{`notify_osc777() {
    local title="$1"
    local body="$2"
    printf '\\e]777;notify;%s;%s\\a' "$title" "$body"
}

notify_osc777 "Build Complete" "All tests passed"`}</CodeBlock>

      <h3>{t("osc99Title")}</h3>
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

      <h2>{t("claudeCodeHooks")}</h2>
      <p>
        {t.rich("claudeCodeHooksDesc", {
          link: (chunks) => (
            <a href="https://docs.anthropic.com/en/docs/claude-code">{chunks}</a>
          ),
        })}
      </p>

      <h3>{t("createHookScript")}</h3>
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

      <h3>{t("configureClaude")}</h3>
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

      <h2>{t("integrationExamples")}</h2>

      <h3>{t("notifyAfterLong")}</h3>
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

      <h3>{t("python")}</h3>
      <CodeBlock title="python" lang="python">{`import sys

def notify(title: str, body: str):
    """Send OSC 777 notification."""
    sys.stdout.write(f'\\x1b]777;notify;{title};{body}\\x07')
    sys.stdout.flush()

notify("Script Complete", "Processing finished")`}</CodeBlock>

      <h3>{t("nodejs")}</h3>
      <CodeBlock title="node" lang="javascript">{`function notify(title, body) {
  process.stdout.write(\`\\x1b]777;notify;\${title};\${body}\\x07\`);
}

notify('Build Done', 'webpack finished');`}</CodeBlock>

      <h3>{t("tmuxPassthrough")}</h3>
      <p>{t("tmuxDesc")}</p>
      <CodeBlock title=".tmux.conf" lang="bash">{`set -g allow-passthrough on`}</CodeBlock>
      <CodeBlock lang="bash">{`printf '\\ePtmux;\\e\\e]777;notify;Title;Body\\a\\e\\\\'`}</CodeBlock>
    </>
  );
}
