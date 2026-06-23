import type { Metadata } from "next";
import { LandingCTA } from "../landing-ui";

export const metadata: Metadata = {
  title: "A terminal for Claude Code — cmux",
  description:
    "cmux is a native macOS terminal built for running Claude Code: workspaces that organize parallel agents, notification rings when Claude needs you, Claude Code teams as native panes, and a scriptable CLI.",
  alternates: { canonical: "https://cmux.com/claude-code-terminal" },
};

export default function ClaudeCodeTerminalPage() {
  return (
    <>
      <h1>A terminal for Claude Code</h1>
      <p>
        cmux is a native macOS terminal built for running AI coding agents, and
        Claude Code is a first-class fit. cmux is just a terminal, so{" "}
        <code>claude</code> runs in any workspace out of the box, and the things
        that make running agents painful, keeping track of many at once and
        noticing when they need you, are what cmux is built for.
      </p>

      <h2>Run many Claude Code sessions, organized</h2>
      <p>
        Open a workspace per task and run Claude Code in each. The vertical
        sidebar shows every workspace with its git branch, directory, ports, and
        the latest line of Claude&apos;s output, so a dozen parallel sessions
        stay legible instead of buried in tabs.
      </p>

      <h2>Notification rings when Claude needs you</h2>
      <p>
        When Claude Code finishes or asks for input, the pane rings and the
        sidebar shows an unread badge, so you can let several agents run and come
        back to the one that needs a decision. Notifications fire automatically,
        and you can also trigger them from Claude Code hooks.
      </p>

      <h2>Claude Code teams as native panes</h2>
      <p>
        cmux runs Claude Code&apos;s teammate mode with one command, and the
        teammates spawn as native cmux splits with their own sidebar metadata and
        notifications, no tmux required. See the{" "}
        <a href="https://cmux.com/docs/agent-integrations/claude-code-teams" className="underline underline-offset-2">
          Claude Code teams docs
        </a>
        .
      </p>

      <h2>Scriptable</h2>
      <p>
        Every action is available through the cmux CLI and a Unix socket: create
        a workspace, launch Claude Code in it, send input, read the screen, and
        drive an in-app browser to verify changes, all from a script.
      </p>

      <LandingCTA
        related={[
          { href: "/codex-cli", label: "A terminal for Codex CLI" },
          { href: "/opencode", label: "A terminal for OpenCode" },
          { href: "/docs/agent-integrations/claude-code-teams", label: "Claude Code teams" },
          { href: "/docs/notifications", label: "Notifications" },
        ]}
      />
    </>
  );
}
