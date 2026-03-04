import type { Metadata } from "next";
import Link from "next/link";
import { DownloadButton } from "../../components/download-button";
import { GitHubButton } from "../../components/github-button";

export const metadata: Metadata = {
  title:
    "cmux vs Cursor vs Conductor vs Emdash vs Superset vs Zed",
  description:
    "How cmux compares to Cursor, Conductor, Emdash, Superset, and Zed for running AI coding agents.",
  keywords: [
    "cmux",
    "Cursor",
    "Conductor",
    "Emdash",
    "Superset",
    "Zed",
    "AI coding agents",
    "terminal",
    "Claude Code",
    "Codex",
    "comparison",
  ],
  openGraph: {
    title:
      "cmux vs Cursor vs Conductor vs Emdash vs Superset vs Zed",
    description:
      "How cmux compares to Cursor, Conductor, Emdash, Superset, and Zed for running AI coding agents.",
    type: "article",
    publishedTime: "2026-03-03T00:00:00Z",
    url: "https://cmux.dev/blog/cmux-vs-cursor-conductor-emdash-superset-zed",
  },
  twitter: {
    card: "summary",
    title:
      "cmux vs Cursor vs Conductor vs Emdash vs Superset vs Zed",
    description:
      "How cmux compares to Cursor, Conductor, Emdash, Superset, and Zed for running AI coding agents.",
  },
  alternates: {
    canonical:
      "https://cmux.dev/blog/cmux-vs-cursor-conductor-emdash-superset-zed",
  },
};

export default function ComparisonPage() {
  return (
    <>
      <div className="mb-8">
        <Link
          href="/blog"
          className="text-sm text-muted hover:text-foreground transition-colors"
        >
          &larr; Back to blog
        </Link>
      </div>

      <h1>cmux vs Cursor vs Conductor vs Emdash vs Superset vs Zed</h1>
      <time dateTime="2026-03-03" className="text-sm text-muted">
        March 3, 2026
      </time>

      <p className="mt-6">
        New tools for running AI coding agents keep appearing. Some are
        terminals, some are IDEs, some are orchestrators. Here&apos;s how six of
        them compare.
      </p>

      <h2>cmux</h2>

      <p>
        <a href="https://cmux.dev">cmux</a> is a native macOS terminal built
        on <a href="https://ghostty.org">Ghostty</a> (libghostty). Vertical
        tabs, split panes, a notification system that tells you which agent
        needs attention, and an in-app browser with a scriptable automation API.
        Everything is programmable through a CLI and Unix socket.
      </p>

      <p>
        cmux is a primitive, not a solution. It gives you a terminal, a browser,
        notifications, workspaces, splits, tabs, and a CLI to control all of it.
        It doesn&apos;t force you into an opinionated way to use coding agents.
        What you build with the primitives is yours.
      </p>

      <p>
        Most orchestrator tools require one worktree per agent. cmux
        doesn&apos;t. You can run five agents in one directory, or one agent per
        worktree, or any combination. cmux doesn&apos;t manage your git
        workflow. It gives you terminals, and you decide how to organize them.
        Some people use worktrees. Some use branches. Some just run everything
        in one checkout. cmux works the same either way.
      </p>

      <p>
        Because it&apos;s a terminal, cmux works with every CLI agent: Claude
        Code, Codex, OpenCode, Gemini CLI, Aider, Goose, Amp, Kiro, whatever
        comes next. No integration to maintain. The best developers have always
        built their own tools. Give a million developers composable primitives
        and they&apos;ll collectively find the most efficient workflows faster
        than any product team could design top-down.
      </p>

      <ul>
        <li><strong>Platform:</strong> macOS</li>
        <li><strong>Stack:</strong> Swift, AppKit, libghostty (GPU-accelerated)</li>
        <li><strong>License:</strong> AGPL-3.0</li>
        <li><strong>Price:</strong> Free and open source</li>
      </ul>

      <h2>Cursor</h2>

      <p>
        <a href="https://cursor.com">Cursor</a> is a VS Code fork rebuilt
        around AI. Tab completion, chat sidebar, inline editing
        with <code>Cmd+K</code>, and an agent mode that implements changes
        across multiple files. Background Agents run on cloud VMs and open PRs
        without blocking your editor. BugBot reviews PRs automatically.
      </p>

      <p>
        Cursor is great if you want AI deeply integrated into your editing
        experience. The tab completion model is custom-trained and widely
        considered best in class. Background Agents let you fire off work and
        come back to a PR.
      </p>

      <p>
        Cursor is an IDE, not a terminal. If your workflow is terminal-first
        (Claude Code, Codex, shell scripts), you&apos;re using Cursor&apos;s
        integrated terminal rather than a purpose-built environment. Running 5+
        CLI agents in parallel inside Cursor is possible but not what
        it&apos;s optimized for.
      </p>

      <ul>
        <li><strong>Platform:</strong> macOS, Windows, Linux</li>
        <li><strong>Stack:</strong> Electron (VS Code fork)</li>
        <li><strong>License:</strong> Proprietary</li>
        <li><strong>Price:</strong> Free tier, Pro $20/mo, Ultra $200/mo</li>
      </ul>

      <h2>Zed</h2>

      <p>
        <a href="https://zed.dev">Zed</a> is an open-source editor built in
        Rust by the creators of Atom and Tree-sitter. GPU-accelerated at 120fps
        with millisecond typing latency. The Agent Panel has built-in tools for
        filesystem, terminal, and codebase search. The{" "}
        <a href="https://zed.dev/acp">Agent Client Protocol</a> (ACP) lets
        external agents like Claude Code, Codex, and Gemini CLI plug into
        Zed&apos;s UI.
      </p>

      <p>
        Zed&apos;s bet is being the universal host for any agent rather than
        building the best built-in one. ACP is an open standard that other
        editors are adopting too (Neovim, Emacs, JetBrains). You can run
        multiple agent threads in tabs and switch between them.
      </p>

      <p>
        Like Cursor, Zed is an editor first. The agent features are layered on
        top of the editing experience. If you spend most of your time in CLI
        agents rather than in an editor, Zed&apos;s agent panel is a window
        into the agent rather than the agent&apos;s native environment. The
        multi-agent story is still maturing compared to purpose-built tools.
      </p>

      <ul>
        <li><strong>Platform:</strong> macOS, Windows, Linux</li>
        <li><strong>Stack:</strong> Rust, GPU-accelerated</li>
        <li><strong>License:</strong> GPL v3</li>
        <li><strong>Price:</strong> Free, Pro $10/mo for hosted models</li>
      </ul>

      <h2>Conductor</h2>

      <p>
        <a href="https://conductor.build">Conductor</a> is a macOS app from
        the team behind Melty (YC S24). You add a GitHub repo, create
        workspaces, and assign tasks to Claude Code or Codex. Each workspace
        gets an isolated worktree. You review changes in a diff viewer and
        create PRs from within the app.
      </p>

      <p>
        Conductor is polished and focused. The diff-first review model makes
        sense: review time scales with change size, not codebase size. If you
        only use Claude Code and Codex and want a clean GUI for parallel
        execution, Conductor is a good pick.
      </p>

      <p>
        The constraints: macOS only (Apple Silicon), GitHub-only cloning, and
        only Claude Code and Codex are supported. There&apos;s no terminal
        access. When you need to debug something an agent got wrong,
        you&apos;re in Conductor&apos;s diff view rather than a shell.
        Closed-source, so you&apos;re dependent on the team to add support for
        new agents.
      </p>

      <ul>
        <li><strong>Platform:</strong> macOS (Apple Silicon)</li>
        <li><strong>Stack:</strong> Native macOS app</li>
        <li><strong>License:</strong> Proprietary</li>
        <li><strong>Price:</strong> Free</li>
      </ul>

      <h2>Emdash</h2>

      <p>
        <a href="https://www.emdash.sh">Emdash</a> is an Electron app that
        orchestrates multiple CLI agents in parallel, each in an isolated git
        worktree. Supports 22+ agents by auto-detecting installed CLIs. Kanban
        board view, built-in diff viewer, issue integration with Linear, Jira,
        and GitHub, and a best-of-N mode where you run the same task across
        multiple agents and pick the winner.
      </p>

      <p>
        The Kanban view is genuinely useful for tracking what agents are working
        on. Issue integration means you can pull tasks from Linear and assign
        them to agents. The worktree isolation means agents can&apos;t conflict
        with each other.
      </p>

      <p>
        The question with orchestrator GUIs is how well the abstraction ages.
        When an agent fails mid-task, you need the actual terminal output, the
        filesystem, a shell. Emdash wraps agents in its UI, which is smooth when
        things work and adds friction when they don&apos;t.
      </p>

      <ul>
        <li><strong>Platform:</strong> macOS, Windows, Linux</li>
        <li><strong>Stack:</strong> Electron, TypeScript, React</li>
        <li><strong>License:</strong> MIT</li>
        <li><strong>Price:</strong> Free and open source</li>
      </ul>

      <h2>Superset</h2>

      <p>
        <a href="https://superset.sh">Superset</a> is an Electron app with
        xterm.js terminals for running agents in parallel with worktree
        isolation. Built-in diff viewer, IDE deep-linking (VS Code, Cursor,
        Xcode, JetBrains), workspace presets for automating environment setup,
        and port forwarding.
      </p>

      <p>
        Superset is agent-agnostic and gives you actual terminal sessions,
        closer to cmux in philosophy than Conductor or Emdash. The workspace
        presets are useful for complex per-project setup.
      </p>

      <p>
        Electron/xterm.js rendering is noticeably slower than native
        GPU-accelerated terminals, especially with high-throughput agent output.
        The naming collision with Apache Superset makes it hard to search for.
      </p>

      <ul>
        <li><strong>Platform:</strong> macOS (Windows/Linux untested)</li>
        <li><strong>Stack:</strong> Electron, xterm.js, React</li>
        <li><strong>License:</strong> Apache 2.0</li>
        <li><strong>Price:</strong> Free tier, Pro $20/mo</li>
      </ul>

      <h2>How to think about this</h2>

      <p>
        These tools fall into two camps.
      </p>

      <p>
        <strong>Orchestrator GUIs</strong> (Conductor, Emdash, Superset) wrap
        agents in a purpose-built interface. They manage worktrees, show diffs,
        handle the git workflow. Clean experience for the common case. When
        things go sideways, you&apos;re debugging through someone else&apos;s UI.
      </p>

      <p>
        <strong>Development environments</strong> (cmux, Cursor, Zed) give you
        a general-purpose tool that happens to be good for agents. Cursor and
        Zed are editors with AI layered on. cmux is a terminal with
        agent-awareness layered on. All three give you full access to the
        underlying systems.
      </p>

      <p>
        Nobody has figured out the best way to work with agents yet. The
        orchestrator GUIs are betting that worktree-per-agent with a Kanban
        board is the right workflow. Maybe it is. But the teams building closed
        products are guessing just like everyone else. The developers closest to
        their own codebases will figure it out first. They just need the right
        primitives.
      </p>

      <p>
        cmux gives you a terminal, a browser, notifications, and a socket API.
        The rest is up to you.
      </p>

      <div className="flex flex-wrap items-center justify-center gap-3 mt-12">
        <DownloadButton location="blog-bottom" />
        <GitHubButton />
      </div>
    </>
  );
}
