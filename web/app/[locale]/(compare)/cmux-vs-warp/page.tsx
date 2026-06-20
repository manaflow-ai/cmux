import type { Metadata } from "next";
import { CompareCTA, CompareTable } from "../compare-ui";

export const metadata: Metadata = {
  title: "cmux vs Warp: AI terminals for macOS compared — cmux",
  description:
    "Warp builds AI into the terminal behind an account. cmux is a native macOS terminal on libghostty that works with the CLI agents you already use, with no required account, plus vertical tabs and notification rings.",
  alternates: { canonical: "https://cmux.com/cmux-vs-warp" },
};

export default function CmuxVsWarpPage() {
  return (
    <>
      <h1>cmux vs Warp</h1>
      <p>
        Both aim at developers working with AI, but they take different routes.
        Warp is a Rust-based terminal with its own AI assistant, a blocks-based
        command UI, and an account model. cmux is a native macOS terminal built
        on libghostty that stays out of the way and works with whatever CLI
        agent you already run, from Claude Code to Codex to OpenCode.
      </p>

      <h2>At a glance</h2>
      <CompareTable
        headers={["", "cmux", "Warp"]}
        rows={[
          [
            "AI model",
            "Bring your own CLI agent",
            "Built-in assistant plus your own",
          ],
          ["Account", "Not required to use the terminal", "Account-based"],
          ["Platform", "macOS, native Swift and AppKit", "macOS, Linux, Windows"],
          ["Rendering", "GPU-accelerated via libghostty", "GPU-accelerated, custom"],
          [
            "Organization",
            "Vertical tabs and workspace groups",
            "Tabs, panes, and blocks",
          ],
          [
            "Agent notifications",
            "Notification rings when an agent needs attention",
            "Activity indicators",
          ],
          ["License", "Open source", "Proprietary"],
        ]}
      />

      <h2>When Warp is the better fit</h2>
      <p>
        Choose Warp if you want a built-in AI assistant and the blocks command
        interface as first-class features, or if you need the same terminal on
        Linux and Windows as well as macOS.
      </p>

      <h2>When cmux is the better fit</h2>
      <p>
        cmux is macOS-native and agent-agnostic. There is no required account to
        open a terminal, and it orchestrates the agents you already pay for
        instead of adding another. The sidebar organizes parallel work by
        workspace with live git, directory, and port status, and panes ring when
        an agent needs you. It is open source and built on libghostty.
      </p>

      <CompareCTA
        related={[
          { href: "/cmux-vs-tmux", label: "cmux vs tmux" },
          { href: "/cmux-vs-iterm2", label: "cmux vs iTerm2" },
          { href: "/best-terminal-for-mac", label: "Best terminal for Mac" },
          {
            href: "/docs/getting-started",
            label: "Get started with cmux",
          },
        ]}
      />
    </>
  );
}
