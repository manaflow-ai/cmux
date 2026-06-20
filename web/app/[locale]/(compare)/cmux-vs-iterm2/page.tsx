import type { Metadata } from "next";
import { CompareCTA, CompareTable } from "../compare-ui";

export const metadata: Metadata = {
  title: "cmux vs iTerm2: a macOS terminal comparison — cmux",
  description:
    "iTerm2 is the long-standing, feature-rich macOS terminal. cmux is a newer native terminal on libghostty, purpose-built for AI coding agents with vertical tabs, workspace organization, and notification rings.",
  alternates: { canonical: "https://cmux.com/cmux-vs-iterm2" },
};

export default function CmuxVsIterm2Page() {
  return (
    <>
      <h1>cmux vs iTerm2</h1>
      <p>
        Both are native macOS terminals, so this comes down to what you optimize
        for. iTerm2 is the mature, deeply configurable terminal that has been
        the macOS default-replacement for years. cmux is newer, built on
        libghostty for GPU-accelerated rendering, and shaped around one job:
        running AI coding agents and keeping many of them organized.
      </p>

      <h2>At a glance</h2>
      <CompareTable
        headers={["", "cmux", "iTerm2"]}
        rows={[
          [
            "Rendering",
            "GPU-accelerated via libghostty",
            "CPU and Metal renderer",
          ],
          [
            "Organization",
            "Vertical tabs and workspace groups with live status",
            "Horizontal tabs, split panes, profiles",
          ],
          [
            "Agent notifications",
            "Notification rings when an agent needs attention",
            "Shell-triggered alerts and badges",
          ],
          [
            "In-app browser",
            "Scriptable browser pane alongside the terminal",
            "None",
          ],
          [
            "Maturity",
            "Newer, focused feature set",
            "Very mature, broad feature set",
          ],
          ["Built with", "Native Swift and AppKit", "Native Objective-C"],
        ]}
      />

      <h2>When iTerm2 is the better fit</h2>
      <p>
        iTerm2 has a deep, battle-tested feature set: tmux control-mode
        integration, triggers, deep profile customization, and years of edge
        cases handled. If you want maximum configurability and are not
        organizing fleets of agents, iTerm2 is hard to beat.
      </p>

      <h2>When cmux is the better fit</h2>
      <p>
        cmux is built for the agent workflow. The vertical sidebar shows each
        workspace with its git branch, directory, and ports, panes ring when an
        agent is waiting on you, and workspace groups keep parallel tasks tidy.
        It renders on libghostty and ships as a native Swift app with no
        Electron. Pick cmux when your day is spent driving Claude Code, Codex,
        OpenCode, or similar across many repos at once.
      </p>

      <CompareCTA
        related={[
          { href: "/cmux-vs-tmux", label: "cmux vs tmux" },
          { href: "/cmux-vs-warp", label: "cmux vs Warp" },
          { href: "/best-terminal-for-mac", label: "Best terminal for Mac" },
          { href: "/docs/notifications", label: "Notification rings docs" },
        ]}
      />
    </>
  );
}
