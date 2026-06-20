import type { Metadata } from "next";
import { CompareCTA, CompareTable } from "../compare-ui";

export const metadata: Metadata = {
  title: "cmux vs tmux: which terminal multiplexer for macOS? — cmux",
  description:
    "cmux and tmux solve different layers. tmux multiplexes any terminal over SSH on any OS. cmux is a native macOS terminal on libghostty with vertical tabs, workspace organization, and notification rings for AI coding agents.",
  alternates: { canonical: "https://cmux.com/cmux-vs-tmux" },
};

export default function CmuxVsTmuxPage() {
  return (
    <>
      <h1>cmux vs tmux</h1>
      <p>
        These two tools work at different layers, so it is less &ldquo;which one
        wins&rdquo; and more &ldquo;where each one fits.&rdquo; tmux is a
        terminal multiplexer: it splits one terminal into panes and windows
        inside any emulator, on any OS, and keeps sessions alive on a server
        over SSH. cmux is a native macOS terminal application built on
        libghostty, with its own GPU-rendered terminal, vertical tabs, workspace
        organization, and notification rings built for running AI coding agents.
      </p>

      <h2>At a glance</h2>
      <CompareTable
        headers={["", "cmux", "tmux"]}
        rows={[
          ["Type", "Native macOS terminal app", "Terminal multiplexer"],
          ["Platform", "macOS", "Linux, macOS, BSD, anywhere"],
          [
            "Rendering",
            "GPU-accelerated via libghostty",
            "Inherits the host emulator",
          ],
          [
            "Organization",
            "Vertical tabs and workspace groups in the sidebar",
            "Windows and panes by index, prefix-driven",
          ],
          [
            "Agent notifications",
            "Notification rings when an agent needs attention",
            "None built in",
          ],
          [
            "Remote sessions",
            "Built-in SSH and remote tmux attach",
            "Core strength: detach and reattach over SSH",
          ],
          [
            "Learning curve",
            "Mouse and standard macOS shortcuts",
            "Prefix key and a config language",
          ],
        ]}
      />

      <h2>When tmux is the better fit</h2>
      <p>
        Reach for tmux when you need cross-platform multiplexing, server-side
        persistence that survives a dropped SSH connection, or pane management
        from inside whatever emulator you already run. It is the right tool on a
        Linux box you never look at directly.
      </p>

      <h2>When cmux is the better fit</h2>
      <p>
        cmux is built for running many AI coding agents in parallel on a Mac.
        The sidebar shows each workspace with its git branch, working directory,
        ports, and the latest line of agent output, and a pane lights up the
        moment an agent needs input. You get visual organization and
        notifications without memorizing a prefix language. When you do need
        tmux, cmux attaches to remote tmux sessions over SSH, so the two are not
        mutually exclusive.
      </p>

      <CompareCTA
        related={[
          { href: "/cmux-vs-iterm2", label: "cmux vs iTerm2" },
          { href: "/cmux-vs-warp", label: "cmux vs Warp" },
          { href: "/best-terminal-for-mac", label: "Best terminal for Mac" },
          { href: "/docs/ssh", label: "Remote SSH and tmux docs" },
        ]}
      />
    </>
  );
}
