import type { Metadata } from "next";
import { LandingCTA } from "../landing-ui";

export const metadata: Metadata = {
  title: "A terminal for OpenCode — cmux",
  description:
    "cmux is a native macOS terminal built for running OpenCode: workspaces that organize parallel agents, notification rings, and oh-my-opencode multi-model orchestration as native cmux splits.",
  alternates: { canonical: "https://cmux.com/opencode" },
};

export default function OpenCodePage() {
  return (
    <>
      <h1>A terminal for OpenCode</h1>
      <p>
        cmux is a native macOS terminal built for AI coding agents, and OpenCode
        runs in it out of the box. cmux is just a terminal, so{" "}
        <code>opencode</code> works in any workspace, with cmux providing the
        multitasking, organization, and programmability around it.
      </p>

      <h2>Organize many OpenCode sessions</h2>
      <p>
        Run OpenCode per task in its own workspace. The vertical sidebar shows
        each with its git branch, directory, ports, and latest output, so
        parallel runs stay organized.
      </p>

      <h2>Notification rings</h2>
      <p>
        When OpenCode needs you, the pane rings and the sidebar marks it unread,
        so you can run several at once and come back to the one waiting on a
        decision.
      </p>

      <h2>oh-my-opencode multi-model orchestration</h2>
      <p>
        cmux ships <code>cmux omo</code>, which runs OpenCode with the
        oh-my-openagent plugin so multiple models (Claude, GPT, Gemini, Grok)
        orchestrate as parallel agents, and each spawned agent becomes a native
        cmux split. See the{" "}
        <a href="https://cmux.com/docs/agent-integrations/oh-my-opencode" className="underline underline-offset-2">
          oh-my-opencode docs
        </a>
        .
      </p>

      <h2>Scriptable</h2>
      <p>
        Every action is available through the cmux CLI and a Unix socket, so you
        can create workspaces, launch OpenCode, send input, read the screen, and
        drive an in-app browser from a script.
      </p>

      <LandingCTA
        related={[
          { href: "/claude-code-terminal", label: "A terminal for Claude Code" },
          { href: "/codex-cli", label: "A terminal for Codex CLI" },
          { href: "/docs/agent-integrations/oh-my-opencode", label: "oh-my-opencode" },
          { href: "/docs/getting-started", label: "Get started with cmux" },
        ]}
      />
    </>
  );
}
