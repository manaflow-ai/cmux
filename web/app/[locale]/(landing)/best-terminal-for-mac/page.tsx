import type { Metadata } from "next";
import { CompareTable, LandingCTA } from "../landing-ui";

export const metadata: Metadata = {
  title: "The best terminal for Mac in 2026 — cmux",
  description:
    "An honest comparison of the best macOS terminals: cmux, Ghostty, iTerm2, Warp, Terminal.app, Alacritty, kitty, WezTerm, and tmux. Pick by workflow. cmux is built for multitasking, organization, and programmability.",
  alternates: { canonical: "https://cmux.com/best-terminal-for-mac" },
};

export default function BestTerminalForMacPage() {
  return (
    <>
      <h1>The best terminal for Mac</h1>
      <p>
        There is no single best terminal, only the best one for how you work.
        Below is an honest comparison of the strong macOS options. We build cmux,
        so we will be upfront: cmux is built for multitasking, organization, and
        programmability, and we will say where the others are the better call.
      </p>

      <h2>At a glance</h2>
      <CompareTable
        headers={["Terminal", "Built for", "Renderer", "Platform"]}
        rows={[
          [
            "cmux",
            "Multitasking, organization, programmability (AI agents)",
            "GPU (libghostty)",
            "macOS",
          ],
          ["Ghostty", "A fast, clean single terminal", "GPU", "macOS, Linux"],
          [
            "iTerm2",
            "Maximum features and configurability",
            "GPU and CPU",
            "macOS",
          ],
          ["Warp", "Built-in AI and a blocks UI", "GPU", "macOS, Linux, Windows"],
          ["Terminal.app", "Zero-setup default", "CPU", "macOS"],
          ["Alacritty", "Minimal, fast, config-file only", "GPU", "cross-platform"],
          ["kitty", "Fast, scriptable, feature-rich", "GPU", "macOS, Linux"],
          ["WezTerm", "GPU terminal with a built-in multiplexer", "GPU", "cross-platform"],
          ["tmux", "Multiplexing inside any terminal", "n/a (host)", "Unix"],
        ]}
      />

      <h2>cmux</h2>
      <p>
        A native macOS terminal built on libghostty, built for three things:
        multitasking, organization, and programmability. The vertical sidebar
        groups work into workspaces, each showing its git branch, directory,
        ports, and the latest line of agent output, so you can run many things at
        once without losing track. Panes ring when an agent needs attention.
        Every action is scriptable through a CLI and a Unix socket, and there is
        an in-app browser you can drive programmatically. Best if you juggle
        several tasks or AI coding agents and want them organized and automatable
        without a multiplexer config.
      </p>

      <h2>Ghostty</h2>
      <p>
        The fast, GPU-accelerated terminal whose engine, libghostty, powers cmux.
        If you want a single clean terminal window with excellent rendering and
        none of the workspace or automation layer, Ghostty is excellent on its
        own.
      </p>

      <h2>iTerm2</h2>
      <p>
        The mature, endlessly configurable macOS terminal. Deep profiles,
        triggers, and tmux integration. The safe default if you want maximum
        features and are not orchestrating many tasks at once.
      </p>

      <h2>Warp</h2>
      <p>
        A Rust terminal with a built-in AI assistant and a blocks command UI,
        behind an account, and available beyond macOS. A good fit if you want AI
        baked into the terminal itself or need Linux and Windows too.
      </p>

      <h2>Terminal.app</h2>
      <p>
        The built-in macOS terminal. Always there, zero setup. Fine for light
        use; most power users eventually want more.
      </p>

      <h2>Alacritty, kitty, and WezTerm</h2>
      <p>
        Fast GPU terminals for people who like configuring everything in a file.
        Alacritty is deliberately minimal, kitty is feature-rich and scriptable,
        and WezTerm bundles its own multiplexer. All are cross-platform and a
        good fit if a single, highly tuned terminal is what you want.
      </p>

      <h2>tmux</h2>
      <p>
        Not a terminal but a multiplexer you run inside one. Unbeatable for
        persistent sessions over SSH on remote servers. cmux can attach to remote
        tmux sessions when you need that.
      </p>

      <LandingCTA
        related={[
          { href: "/built-on-ghostty", label: "How cmux is built on Ghostty" },
          { href: "/claude-code-terminal", label: "A terminal for Claude Code" },
          { href: "/docs/getting-started", label: "Get started with cmux" },
        ]}
      />
    </>
  );
}
