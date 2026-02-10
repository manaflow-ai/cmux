import type { Metadata } from "next";
import { CodeBlock } from "../../components/code-block";
import { Callout } from "../../components/callout";

export const metadata: Metadata = {
  title: "Notifications",
  description: "Desktop notifications in cmux for AI agents and scripts",
};

export default function NotificationsPage() {
  return (
    <>
      <h1>Notifications</h1>
      <p>
        cmux supports desktop notifications, allowing AI agents and scripts to
        alert you when they need attention.
      </p>

      <h2>Lifecycle</h2>
      <ol>
        <li>
          <strong>Received</strong> — notification appears in panel, desktop
          alert fires (if not suppressed)
        </li>
        <li>
          <strong>Unread</strong> — badge shown on workspace tab
        </li>
        <li>
          <strong>Read</strong> — cleared when you view that workspace
        </li>
        <li>
          <strong>Cleared</strong> — removed from panel
        </li>
      </ol>

      <h3>Suppression</h3>
      <p>Desktop alerts are suppressed when:</p>
      <ul>
        <li>The cmux window is focused</li>
        <li>The specific workspace sending the notification is active</li>
        <li>The notification panel is open</li>
      </ul>

      <h3>Notification panel</h3>
      <p>
        Press <code>⌘⇧I</code> to open the notification panel. Click a
        notification to jump to that workspace. Press <code>⌘⇧U</code> to jump
        directly to the workspace with the most recent unread notification.
      </p>

      <h2>Sending notifications</h2>

      <h3>CLI</h3>
      <CodeBlock lang="bash">{`cmux notify --title "Task Complete" --body "Your build finished"
cmux notify --title "Claude Code" --subtitle "Waiting" --body "Agent needs input"`}</CodeBlock>

      <h3>OSC 777 (simple)</h3>
      <p>
        The RXVT protocol uses a fixed format with title and body:
      </p>
      <CodeBlock lang="bash">{`printf '\\e]777;notify;My Title;Message body here\\a'`}</CodeBlock>
      <CodeBlock title="Shell function" lang="bash">{`notify_osc777() {
    local title="$1"
    local body="$2"
    printf '\\e]777;notify;%s;%s\\a' "$title" "$body"
}

notify_osc777 "Build Complete" "All tests passed"`}</CodeBlock>

      <h3>OSC 99 (rich)</h3>
      <p>
        The Kitty protocol supports subtitles and notification IDs:
      </p>
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
            <th>Feature</th>
            <th>OSC 99</th>
            <th>OSC 777</th>
          </tr>
        </thead>
        <tbody>
          <tr>
            <td>Title + body</td>
            <td>Yes</td>
            <td>Yes</td>
          </tr>
          <tr>
            <td>Subtitle</td>
            <td>Yes</td>
            <td>No</td>
          </tr>
          <tr>
            <td>Notification ID</td>
            <td>Yes</td>
            <td>No</td>
          </tr>
          <tr>
            <td>Complexity</td>
            <td>Higher</td>
            <td>Lower</td>
          </tr>
        </tbody>
      </table>

      <Callout>
        Use OSC 777 for simple notifications. Use OSC 99 when you need subtitles
        or notification IDs. Use the CLI (<code>cmux notify</code>) for the
        easiest integration.
      </Callout>

      <h2>Claude Code hooks</h2>
      <p>
        cmux integrates with{" "}
        <a href="https://docs.anthropic.com/en/docs/claude-code">Claude Code</a>{" "}
        via hooks to notify you when tasks complete.
      </p>

      <h3>1. Create the hook script</h3>
      <CodeBlock title="~/.claude/hooks/cmux-notify.sh" lang="bash">{`#!/bin/bash
# Skip if not in cmux
[ -S /tmp/cmux.sock ] || exit 0

EVENT=$(cat)
EVENT_TYPE=$(echo "$EVENT" | jq -r '.event // "unknown"')
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

      <h3>2. Configure Claude Code</h3>
      <CodeBlock title="~/.claude/settings.json" lang="json">{`{
  "hooks": {
    "Stop": ["~/.claude/hooks/cmux-notify.sh"],
    "PostToolUse": [
      {
        "matcher": "Task",
        "hooks": ["~/.claude/hooks/cmux-notify.sh"]
      }
    ]
  }
}`}</CodeBlock>
      <p>Restart Claude Code to apply the hooks.</p>

      <h2>Integration examples</h2>

      <h3>Notify after long command</h3>
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

      <h3>Python</h3>
      <CodeBlock title="python" lang="python">{`import sys

def notify(title: str, body: str):
    """Send OSC 777 notification."""
    sys.stdout.write(f'\\x1b]777;notify;{title};{body}\\x07')
    sys.stdout.flush()

notify("Script Complete", "Processing finished")`}</CodeBlock>

      <h3>Node.js</h3>
      <CodeBlock title="node" lang="javascript">{`function notify(title, body) {
  process.stdout.write(\`\\x1b]777;notify;\${title};\${body}\\x07\`);
}

notify('Build Done', 'webpack finished');`}</CodeBlock>

      <h3>tmux passthrough</h3>
      <p>If using tmux inside cmux, enable passthrough:</p>
      <CodeBlock title=".tmux.conf" lang="bash">{`set -g allow-passthrough on`}</CodeBlock>
      <CodeBlock lang="bash">{`printf '\\ePtmux;\\e\\e]777;notify;Title;Body\\a\\e\\\\'`}</CodeBlock>
    </>
  );
}
