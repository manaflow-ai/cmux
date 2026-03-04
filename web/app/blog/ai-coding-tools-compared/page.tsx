import type { Metadata } from "next";
import Link from "next/link";
import { DownloadButton } from "../../components/download-button";
import { GitHubButton } from "../../components/github-button";

export const metadata: Metadata = {
  title: "AI Coding Tools Compared: cmux, Cursor, Emdash, Conductor, Superset",
  description:
    "An honest comparison of tools for running AI coding agents: cmux, Cursor, Emdash, Conductor, and Superset. What each does well and where they differ.",
  keywords: [
    "cmux",
    "Cursor",
    "Emdash",
    "Conductor",
    "Superset",
    "AI coding agents",
    "terminal",
    "Claude Code",
    "Codex",
    "developer tools",
    "comparison",
  ],
  openGraph: {
    title:
      "AI Coding Tools Compared: cmux, Cursor, Emdash, Conductor, Superset",
    description:
      "An honest comparison of tools for running AI coding agents: cmux, Cursor, Emdash, Conductor, and Superset.",
    type: "article",
    publishedTime: "2026-03-03T00:00:00Z",
    url: "https://cmux.dev/blog/ai-coding-tools-compared",
  },
  twitter: {
    card: "summary",
    title:
      "AI Coding Tools Compared: cmux, Cursor, Emdash, Conductor, Superset",
    description:
      "An honest comparison of tools for running AI coding agents: cmux, Cursor, Emdash, Conductor, and Superset.",
  },
  alternates: {
    canonical: "https://cmux.dev/blog/ai-coding-tools-compared",
  },
};

export default function AIToolsComparedPage() {
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

      <h1>AI Coding Tools Compared</h1>
      <time dateTime="2026-03-03" className="text-sm text-muted">
        March 3, 2026
      </time>

      <p className="mt-6">
        A lot of new tools have appeared for running AI coding agents. Some are
        terminals, some are IDEs, some are orchestrators. They all solve a
        version of the same problem: you have multiple agents working on code,
        and you need a way to manage them.
      </p>

      <p>
        Here&apos;s an honest breakdown of five tools we get asked about most,
        including our own.
      </p>

      <h2>cmux</h2>

      <p>
        <a href="https://cmux.dev">cmux</a> is a native macOS terminal built on{" "}
        <a href="https://ghostty.org">Ghostty</a> (libghostty). It has vertical
        tabs, split panes, a notification system for knowing when agents need
        you, and an in-app browser with a scriptable automation API. Everything
        is programmable through a CLI and Unix socket.
      </p>

      <p>
        The core idea: cmux is a terminal, not an orchestrator. Agents run in
        real terminal sessions. You see their actual output. The notification
        system (blue rings on panes, sidebar badges, jump-to-unread with{" "}
        <code>Cmd+Shift+U</code>) tells you which agent needs attention. The
        browser lets agents interact with your dev server through Playwright-style
        commands (click, fill, screenshot, read accessibility trees). The socket
        API lets you build any orchestration workflow on top.
      </p>

      <p>
        Because it&apos;s a terminal, cmux works with every agent that runs in a
        terminal: Claude Code, Codex, OpenCode, Gemini CLI, Aider, Goose, Amp,
        Kiro, whatever comes next. There&apos;s no agent-specific integration to
        maintain.
      </p>

      <ul>
        <li>
          <strong>Platform:</strong> macOS (Apple Silicon and Intel)
        </li>
        <li>
          <strong>Stack:</strong> Swift, AppKit, libghostty (GPU-accelerated)
        </li>
        <li>
          <strong>License:</strong> AGPL-3.0
        </li>
        <li>
          <strong>Price:</strong> Free and open source
        </li>
      </ul>

      <h2>Cursor</h2>

      <p>
        <a href="https://cursor.com">Cursor</a> is a VS Code fork rebuilt
        around AI. It has inline tab completion, a chat sidebar, inline editing
        with <code>Cmd+K</code>, and an agent mode that plans and implements
        changes across multiple files. Background Agents run on cloud VMs and
        open PRs without blocking your editor. BugBot reviews PRs automatically.
      </p>

      <p>
        Cursor is excellent if you want AI deeply integrated into your editing
        experience. The tab completion model is custom-trained and widely
        considered the best in class. Agent mode works well for contained tasks.
        Background Agents let you fire off work and come back to a PR.
      </p>

      <p>
        The tradeoff: Cursor is an IDE, not a terminal. If your workflow is
        terminal-first (Claude Code, Codex, shell scripts), you&apos;re using
        Cursor&apos;s integrated terminal rather than a purpose-built
        environment. Running 5+ agents in parallel inside Cursor&apos;s terminal
        panes is possible but not what it&apos;s optimized for. Cursor is at its
        best when you&apos;re editing code in the editor, not running multiple
        CLI agents.
      </p>

      <ul>
        <li>
          <strong>Platform:</strong> macOS, Windows, Linux
        </li>
        <li>
          <strong>Stack:</strong> Electron (VS Code fork)
        </li>
        <li>
          <strong>License:</strong> Proprietary
        </li>
        <li>
          <strong>Price:</strong> Free tier, Pro $20/mo, Ultra $200/mo
        </li>
      </ul>

      <h2>Emdash</h2>

      <p>
        <a href="https://www.emdash.sh">Emdash</a> is an Electron desktop app
        that orchestrates multiple CLI agents in parallel, each in an isolated
        git worktree. It supports 22+ agents out of the box (Claude Code, Codex,
        Gemini, Amp, Goose, and more) by auto-detecting installed CLIs. It has a
        Kanban board view, built-in diff viewer, issue integration with Linear,
        Jira, and GitHub, and a best-of-N mode where you run the same task
        across multiple agents and pick the winner.
      </p>

      <p>
        Emdash does a lot. The Kanban view is genuinely useful for tracking what
        multiple agents are working on. Issue integration means you can pull
        tasks from Linear and assign them to agents. The worktree isolation
        means agents can&apos;t conflict with each other.
      </p>

      <p>
        The question with Emdash (and all orchestrator GUIs) is how well the
        abstraction ages. When an agent fails mid-task, you often need to see
        the actual terminal output, poke around the file system, run commands.
        Emdash wraps agents in its UI, which is great when things work and adds
        friction when they don&apos;t. It&apos;s also Electron, which matters if
        terminal rendering performance is a priority.
      </p>

      <ul>
        <li>
          <strong>Platform:</strong> macOS, Windows, Linux
        </li>
        <li>
          <strong>Stack:</strong> Electron, TypeScript, React
        </li>
        <li>
          <strong>License:</strong> MIT
        </li>
        <li>
          <strong>Price:</strong> Free and open source
        </li>
      </ul>

      <h2>Conductor</h2>

      <p>
        <a href="https://conductor.build">Conductor</a> is a macOS app from the
        team behind Melty (YC S24). You add a GitHub repo, it clones it,
        and you create workspaces. Each workspace is an isolated worktree where
        you assign tasks to Claude Code or Codex. You review changes in a diff
        viewer and create PRs from within the app.
      </p>

      <p>
        Conductor is polished and focused. The diff-first review model makes
        sense: review time scales with change size, not codebase size. The
        dashboard shows all active agents at a glance. If you only use Claude
        Code and Codex and want a clean GUI for parallel execution, Conductor is
        a good pick.
      </p>

      <p>
        The limitations: macOS only (Apple Silicon required), GitHub-only repo
        cloning, and it only supports Claude Code and Codex. There&apos;s no
        terminal access. When you need to debug something the agent got wrong,
        you&apos;re working through Conductor&apos;s diff view rather than
        dropping into a shell. It&apos;s also closed-source, which means
        you&apos;re dependent on the team to add support for new agents.
      </p>

      <ul>
        <li>
          <strong>Platform:</strong> macOS (Apple Silicon)
        </li>
        <li>
          <strong>Stack:</strong> Native macOS app
        </li>
        <li>
          <strong>License:</strong> Proprietary
        </li>
        <li>
          <strong>Price:</strong> Free
        </li>
      </ul>

      <h2>Superset</h2>

      <p>
        <a href="https://superset.sh">Superset</a> is an Electron app with
        xterm.js terminals, designed for running agents in parallel with
        worktree isolation. It has a built-in diff viewer, IDE deep-linking (VS
        Code, Cursor, Xcode, JetBrains), workspace presets for automating
        environment setup, and port forwarding.
      </p>

      <p>
        Superset is agent-agnostic and gives you actual terminal sessions, which
        puts it closer to cmux in philosophy than Conductor or Emdash. The
        workspace presets are useful if you have complex per-project setup (start
        Docker, seed database, etc.). Port forwarding across parallel
        environments is a nice touch.
      </p>

      <p>
        The tradeoffs: Electron/xterm.js terminal rendering is noticeably slower
        than native GPU-accelerated terminals, especially with high-throughput
        agent output. The naming collision with Apache Superset makes it hard to
        search for. And the Pro tier at $20/month may give pause when the
        orchestration layer on top of agents is where many tools are competing to
        be free.
      </p>

      <ul>
        <li>
          <strong>Platform:</strong> macOS (Windows/Linux untested)
        </li>
        <li>
          <strong>Stack:</strong> Electron, xterm.js, React
        </li>
        <li>
          <strong>License:</strong> Apache 2.0
        </li>
        <li>
          <strong>Price:</strong> Free tier, Pro $20/mo
        </li>
      </ul>

      <h2>How to think about this</h2>

      <p>
        These tools fall into two camps.
      </p>

      <p>
        <strong>Orchestrator GUIs</strong> (Conductor, Emdash, and to some
        extent Superset) wrap agents in a purpose-built interface. They manage
        worktrees, show diffs, and handle the git workflow. The benefit is a
        clean experience for the common case. The cost is that when things go
        sideways, you&apos;re debugging through someone else&apos;s UI instead
        of a terminal.
      </p>

      <p>
        <strong>Development environments</strong> (cmux, Cursor) give you a
        general-purpose tool that happens to be good for agents. Cursor is an
        IDE with AI baked in. cmux is a terminal with agent-awareness baked in.
        Both give you full access to underlying systems. The cost is that
        orchestration is something you build on top, not something that&apos;s
        handed to you.
      </p>

      <p>
        Our bias is obvious, but we think the terminal is the right layer.
        Agents change fast. The CLI tools they ship change fast. A terminal
        doesn&apos;t need to update its integration every time an agent releases
        a new version. It just runs the command. The notification system and
        browser API on top give you the agent-awareness that a plain terminal
        lacks, and the socket API lets you compose whatever orchestration makes
        sense for your workflow.
      </p>

      <p>
        Try a few of these and see what sticks. They solve different problems
        and the right answer depends on whether you think in terminals or in
        GUIs.
      </p>

      <div className="flex flex-wrap items-center justify-center gap-3 mt-12">
        <DownloadButton location="blog-bottom" />
        <GitHubButton />
      </div>
    </>
  );
}
