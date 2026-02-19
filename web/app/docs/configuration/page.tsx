import type { Metadata } from "next";
import { CodeBlock } from "../../components/code-block";
import { Callout } from "../../components/callout";

export const metadata: Metadata = {
  title: "Configuration",
  description:
    "Configure cmux via Ghostty config plus in-app settings for theme, workspace placement, updates, socket automation security, browser defaults, and keyboard shortcuts.",
};

export default function ConfigurationPage() {
  return (
    <>
      <h1>Configuration</h1>
      <p>cmux uses two configuration layers:</p>
      <ul>
        <li>
          <strong>Ghostty config files</strong> for terminal appearance and
          behavior
        </li>
        <li>
          <strong>cmux Settings</strong> (<code>⌘,</code>) for app-level
          features like automation, browser defaults, and shortcut
          customization
        </li>
      </ul>

      <h2>Ghostty config locations</h2>
      <p>cmux looks for Ghostty config in this order:</p>
      <ol>
        <li>
          <code>~/.config/ghostty/config</code>
        </li>
        <li>
          <code>~/Library/Application Support/com.mitchellh.ghostty/config</code>
        </li>
      </ol>
      <p>Create the file if needed:</p>
      <CodeBlock lang="bash">{`mkdir -p ~/.config/ghostty
touch ~/.config/ghostty/config`}</CodeBlock>
      <p>
        You can also open Ghostty&apos;s config from
        <strong> cmux → Ghostty Settings…</strong>.
      </p>

      <h2>Ghostty appearance and behavior</h2>

      <h3>Font</h3>
      <CodeBlock title="~/.config/ghostty/config" lang="ini">{`font-family = JetBrains Mono
font-size = 14`}</CodeBlock>

      <h3>Colors</h3>
      <CodeBlock title="~/.config/ghostty/config" lang="ini">{`# Theme (or use individual colors below)
theme = Dracula

# Custom colors
background = #1e1e2e
foreground = #cdd6f4
cursor-color = #f5e0dc
cursor-text = #1e1e2e
selection-background = #585b70
selection-foreground = #cdd6f4`}</CodeBlock>

      <h3>Split panes</h3>
      <CodeBlock title="~/.config/ghostty/config" lang="ini">{`# Opacity for unfocused splits (0.0 to 1.0)
unfocused-split-opacity = 0.7

# Fill color for unfocused splits
unfocused-split-fill = #1e1e2e

# Divider color between splits
split-divider-color = #45475a`}</CodeBlock>

      <h3>Working directory + scrollback</h3>
      <CodeBlock title="~/.config/ghostty/config" lang="ini">{`# Default directory for new terminals
working-directory = ~/Projects

# Number of lines kept in scrollback
scrollback-limit = 10000`}</CodeBlock>

      <h2>cmux settings</h2>
      <p>
        In-app settings are available via <strong>cmux → Settings</strong> (
        <code>⌘,</code>).
      </p>

      <h3>App</h3>
      <ul>
        <li>
          <strong>Theme</strong> — <code>System</code>, <code>Light</code>, or{" "}
          <code>Dark</code>
        </li>
        <li>
          <strong>New Workspace Placement</strong> — <code>Top</code>,{" "}
          <code>After current</code>, or <code>End</code>
        </li>
        <li>
          <strong>Dock Badge</strong> — show unread count on the app icon
        </li>
      </ul>

      <h3>Updates</h3>
      <ul>
        <li>
          <strong>Receive Nightly Builds</strong> — opt into nightly appcasts
          built from recent <code>main</code> commits
        </li>
      </ul>

      <h3>Automation</h3>
      <p>
        <strong>Socket Control Mode</strong> controls access to the local Unix
        socket:
      </p>
      <ul>
        <li>
          <strong>Off</strong> — disable the control socket
        </li>
        <li>
          <strong>cmux processes only</strong> — only processes spawned inside
          cmux terminals can connect
        </li>
      </ul>
      <Callout type="warn">
        A third mode, <code>allowAll</code>, exists for advanced use via{" "}
        <code>CMUX_SOCKET_MODE</code> only. It is intentionally hidden from the
        Settings UI.
      </Callout>
      <p>Environment variable overrides:</p>
      <CodeBlock lang="bash">{`# Force socket off/on
CMUX_SOCKET_ENABLE=0   # off
CMUX_SOCKET_ENABLE=1   # on

# Override mode (accepted forms)
CMUX_SOCKET_MODE=off
CMUX_SOCKET_MODE=cmuxOnly
CMUX_SOCKET_MODE=allowAll

# Override socket path
CMUX_SOCKET_PATH=/tmp/cmux.sock`}</CodeBlock>

      <h3>Claude Code integration</h3>
      <p>
        The <strong>Claude Code Integration</strong> toggle controls whether
        cmux wraps <code>claude</code> to inject session tracking + notification
        hooks.
      </p>

      <h3>Browser</h3>
      <ul>
        <li>
          <strong>Default Search Engine</strong> — Google, DuckDuckGo, or Bing
        </li>
        <li>
          <strong>Show Search Suggestions</strong> — enable or disable omnibar
          suggestions
        </li>
        <li>
          <strong>Browsing History</strong> — clear stored omnibar history
        </li>
      </ul>

      <h3>Keyboard shortcuts</h3>
      <p>
        You can customize shortcut bindings directly in Settings. Click a
        shortcut value to record a new key combo.
      </p>

      <h3>Reset</h3>
      <p>
        Use <strong>Reset All Settings</strong> to restore app settings and
        shortcut bindings to defaults.
      </p>

      <h2>Example Ghostty config</h2>
      <CodeBlock title="~/.config/ghostty/config" lang="ini">{`# Font
font-family = SF Mono
font-size = 13

# Colors
theme = One Dark

# Scrollback
scrollback-limit = 50000

# Splits
unfocused-split-opacity = 0.85
split-divider-color = #3e4451

# Working directory
working-directory = ~/code`}</CodeBlock>
    </>
  );
}
