import type { Metadata } from "next";
import { CompareCTA } from "../compare-ui";

export const metadata: Metadata = {
  title: "The best terminal for Mac in 2026 — cmux",
  description:
    "A short, honest guide to the best macOS terminals: cmux, Ghostty, iTerm2, Warp, Terminal.app, and tmux. Pick by workflow, with a focus on running AI coding agents.",
  alternates: { canonical: "https://cmux.com/best-terminal-for-mac" },
};

export default function BestTerminalForMacPage() {
  return (
    <>
      <h1>The best terminal for Mac</h1>
      <p>
        There is no single best terminal, only the best one for how you work.
        Below is an honest rundown of the strong macOS options. We build cmux, so
        we will be upfront about where it fits and where the others are the
        better call.
      </p>

      <h2>cmux</h2>
      <p>
        A native macOS terminal built on libghostty, purpose-built for running
        AI coding agents. Vertical tabs show each workspace with its git branch,
        directory, ports, and latest agent output. Notification rings light up a
        pane when an agent needs attention, and workspace groups keep parallel
        tasks organized. It ships as a native Swift and AppKit app with no
        Electron, with an in-app scriptable browser and a socket API. Best if
        you run several coding agents at once and want organization and
        notifications without a multiplexer config.
      </p>

      <h2>Ghostty</h2>
      <p>
        The fast, GPU-accelerated terminal whose engine, libghostty, powers
        cmux. If you want a single clean terminal window with excellent
        rendering and none of the workspace or agent tooling, Ghostty is
        excellent on its own.
      </p>

      <h2>iTerm2</h2>
      <p>
        The mature, endlessly configurable macOS terminal. Deep profiles,
        triggers, and tmux integration. The safe default if you want maximum
        features and are not orchestrating agents.
      </p>

      <h2>Warp</h2>
      <p>
        A Rust terminal with a built-in AI assistant and a blocks command UI,
        behind an account, and available beyond macOS. A good fit if you want
        AI baked into the terminal itself or need Linux and Windows too.
      </p>

      <h2>Terminal.app</h2>
      <p>
        The built-in macOS terminal. Always there, zero setup. Fine for light
        use; most power users eventually want more.
      </p>

      <h2>tmux</h2>
      <p>
        Not a terminal but a multiplexer you run inside one. Unbeatable for
        persistent sessions over SSH on remote servers. cmux can attach to
        remote tmux sessions when you need that.
      </p>

      <CompareCTA
        related={[
          { href: "/cmux-vs-iterm2", label: "cmux vs iTerm2" },
          { href: "/cmux-vs-warp", label: "cmux vs Warp" },
          { href: "/cmux-vs-tmux", label: "cmux vs tmux" },
          { href: "/docs/getting-started", label: "Get started with cmux" },
        ]}
      />
    </>
  );
}
