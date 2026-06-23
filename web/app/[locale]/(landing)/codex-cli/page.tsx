import type { Metadata } from "next";
import { LandingCTA } from "../landing-ui";

export const metadata: Metadata = {
  title: "A terminal for Codex CLI — cmux",
  description:
    "cmux is a native macOS terminal built for running OpenAI Codex CLI: workspaces that organize parallel agents, notification rings when Codex needs you, oh-my-codex, and a scriptable CLI and socket API.",
  alternates: { canonical: "https://cmux.com/codex-cli" },
};

export default function CodexCliPage() {
  return (
    <>
      <h1>A terminal for Codex CLI</h1>
      <p>
        cmux is a native macOS terminal built for AI coding agents, and the
        OpenAI Codex CLI runs in it out of the box. cmux is just a terminal, so{" "}
        <code>codex</code> works in any workspace, with cmux adding the
        multitasking, organization, and programmability around it.
      </p>

      <h2>Organize many Codex sessions</h2>
      <p>
        Run Codex in its own workspace per task. The vertical sidebar shows each
        one with its git branch, directory, ports, and latest output, so several
        parallel Codex runs stay organized instead of lost in tabs.
      </p>

      <h2>Notification rings when Codex needs you</h2>
      <p>
        When Codex finishes or asks for input, the pane rings and the sidebar
        flags it unread, so you can run several at once and return to the one
        that needs attention. Notifications fire automatically and can also be
        driven from agent hooks.
      </p>

      <h2>oh-my-codex</h2>
      <p>
        cmux ships an <code>oh-my-codex</code> integration that runs Codex in a
        cmux-aware environment so its activity surfaces as native cmux panes. See
        the{" "}
        <a href="https://cmux.com/docs/agent-integrations/oh-my-codex" className="underline underline-offset-2">
          oh-my-codex docs
        </a>
        .
      </p>

      <h2>Scriptable</h2>
      <p>
        Everything is available through the cmux CLI and a Unix socket: create a
        workspace, launch Codex, send input, read the screen, take screenshots,
        and drive an in-app browser, all from a script.
      </p>

      <LandingCTA
        related={[
          { href: "/claude-code-terminal", label: "A terminal for Claude Code" },
          { href: "/opencode", label: "A terminal for OpenCode" },
          { href: "/docs/agent-integrations/oh-my-codex", label: "oh-my-codex" },
          { href: "/docs/getting-started", label: "Get started with cmux" },
        ]}
      />
    </>
  );
}
