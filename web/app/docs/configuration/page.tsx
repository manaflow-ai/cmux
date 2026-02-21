import type { Metadata } from "next";
import { CodeBlock } from "../../components/code-block";
import { Callout } from "../../components/callout";

export const metadata: Metadata = {
  title: "Configuration",
  description:
    "Configure cmux via Ghostty config files. Font, theme, colors, split pane styling, scrollback, and app settings for automation mode.",
};

export default function ConfigurationPage() {
  return (
    <>
      <h1>Configuration</h1>
      <p>
        cmux reads configuration from Ghostty config files, giving you familiar
        options if you&apos;re coming from Ghostty.
      </p>

      <h2>Config file locations</h2>
      <p>cmux looks for configuration in these locations (in order):</p>
      <ol>
        <li>
          <code>~/.config/ghostty/config</code>
        </li>
        <li>
          <code>~/Library/Application Support/com.mitchellh.ghostty/config</code>
        </li>
      </ol>
      <p>Create the config file if it doesn&apos;t exist:</p>
      <CodeBlock lang="bash">{`mkdir -p ~/.config/ghostty
touch ~/.config/ghostty/config`}</CodeBlock>

      <h2>Appearance</h2>

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

      <h2>Behavior</h2>

      <h3>Scrollback</h3>
      <CodeBlock title="~/.config/ghostty/config" lang="ini">{`# Number of lines to keep in scrollback buffer
scrollback-limit = 10000`}</CodeBlock>

      <h3>Working directory</h3>
      <CodeBlock title="~/.config/ghostty/config" lang="ini">{`# Default directory for new terminals
working-directory = ~/Projects`}</CodeBlock>

      <h2>App settings</h2>
      <p>
        In-app settings are available via <strong>cmux → Settings</strong> (
        <code>⌘,</code>):
      </p>

      <h3>Theme mode</h3>
      <ul>
        <li>
          <strong>System</strong> — follow macOS appearance
        </li>
        <li>
          <strong>Light</strong> — always light mode
        </li>
        <li>
          <strong>Dark</strong> — always dark mode
        </li>
      </ul>

      <h3>Automation mode</h3>
      <p>Control socket access level:</p>
      <ul>
        <li>
          <strong>Off</strong> — no socket control (most secure)
        </li>
        <li>
          <strong>cmux processes only</strong> — only allow processes started
          inside cmux terminals to connect
        </li>
        <li>
          <strong>allowAll</strong> — allow any local process to connect (
          <code>CMUX_SOCKET_MODE=allowAll</code>, env override only)
        </li>
      </ul>
      <Callout type="warn">
        On shared machines, consider using &ldquo;Off&rdquo; or
        &ldquo;cmux processes only&rdquo; mode.
      </Callout>

      <h3>Browser link behavior</h3>
      <p>
        In <strong>Settings → Browser</strong>, cmux exposes two host lists with
        different purposes:
      </p>
      <ul>
        <li>
          <strong>Hosts to Open in Embedded Browser</strong> — applies to links
          clicked from terminal output. Hosts in this list open in cmux; other
          hosts open in your default browser. Supports one host or wildcard per
          line (for example: <code>example.com</code>,{" "}
          <code>*.internal.example</code>).
        </li>
        <li>
          <strong>HTTP Hosts Allowed in Embedded Browser</strong> — applies only
          to HTTP (non-HTTPS) URLs. Hosts in this list can open in cmux without
          a warning prompt.
        </li>
      </ul>

      <h2>Example config</h2>
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
