import type { Metadata } from "next";
import Link from "next/link";

export const metadata: Metadata = {
  title: "The best worktree manager is Claude Code",
  description:
    "How we use a dedicated HQ repo with git worktrees to run parallel agents across codebases, and how you can replicate it.",
  keywords: [
    "cmux",
    "claude code",
    "git worktrees",
    "AI coding agents",
    "developer tools",
    "monorepo",
    "workflow",
    "terminal",
    "macOS",
  ],
  openGraph: {
    title: "The best worktree manager is Claude Code",
    description:
      "How we use a dedicated HQ repo with git worktrees to run parallel agents across codebases, and how you can replicate it.",
    type: "article",
    publishedTime: "2026-03-06T00:00:00Z",
    url: "https://cmux.dev/blog/worktree-manager",
  },
  twitter: {
    card: "summary",
    title: "The best worktree manager is Claude Code",
    description:
      "How we use a dedicated HQ repo with git worktrees to run parallel agents across codebases, and how you can replicate it.",
  },
  alternates: {
    canonical: "https://cmux.dev/blog/worktree-manager",
  },
};

export default function WorktreeManagerPage() {
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

      <h1>The best worktree manager is Claude Code</h1>
      <time dateTime="2026-03-06" className="text-sm text-muted">
        March 6, 2026
      </time>

      <p className="mt-6">
        We run 10+ agents in parallel on the same codebase. Each agent needs its
        own working directory so they don&apos;t step on each other&apos;s files.
        Git worktrees solve this perfectly, and we don&apos;t use a dedicated
        worktree tool. We just put instructions in a <code>CLAUDE.md</code> and
        let Claude Code manage them.
      </p>

      <h2>The HQ pattern</h2>

      <p>
        The setup is a dedicated repo we call <code>cmuxterm-hq</code>. It sits
        outside the main project repo and contains two things: a primary
        checkout and a folder of worktrees.
      </p>

      <pre>
        <code>{`cmuxterm-hq/          # its own git repo
  repo/               # primary checkout of manaflow-ai/cmux (main branch)
  worktrees/
    issue-537-notif-crash/
    issue-541-keychain/
    feat-sidebar-ports/
  CLAUDE.md           # instructions for the orchestrator agent
  scripts/            # shared automation (spawn agents, wait for results, notify)`}</code>
      </pre>

      <p>
        The <code>repo/</code> directory stays on <code>main</code> and is never
        edited directly. It&apos;s the base for creating worktrees. When an
        agent picks up a task, it runs:
      </p>

      <pre>
        <code>{`cd repo
git worktree add ../worktrees/issue-537-notif-crash -b issue-537-notif-crash origin/main`}</code>
      </pre>

      <p>
        Each worktree is a full working copy with its own branch. Agents can
        build, test, and commit independently. When the work is done, the
        worktree gets cleaned up.
      </p>

      <h2>Why a separate repo?</h2>

      <p>
        The HQ repo is not the project repo. This is intentional. The HQ holds
        orchestration scripts, shared skills, board state, and a{" "}
        <code>CLAUDE.md</code> with project-wide conventions. It&apos;s the
        control plane. The worktrees are the data plane.
      </p>

      <p>
        Because the HQ is its own repo, it can version its own automation
        independently. You can iterate on your agent workflow (scripts,
        prompts, conventions) without polluting your project&apos;s commit
        history.
      </p>

      <h2>Multi-repo conditioning</h2>

      <p>
        This pattern scales beyond a single project. If you have an iOS app in
        one repo and a backend in another, the HQ can hold both:
      </p>

      <pre>
        <code>{`my-hq/
  ios-repo/             # primary checkout of the iOS app
  backend-repo/         # primary checkout of the backend
  worktrees/
    ios-issue-42-auth/
    backend-feat-api-v2/
  CLAUDE.md             # instructions that span both codebases`}</code>
      </pre>

      <p>
        The agent sees one <code>CLAUDE.md</code> that knows about both
        codebases. It can reason across them: &quot;the iOS app calls{" "}
        <code>/api/v1/users</code>, the backend is migrating to v2, update
        both.&quot; This is the monorepo benefit without actually merging repos.
      </p>

      <h2>Claude Code as the worktree manager</h2>

      <p>
        We don&apos;t use a separate tool to manage worktrees. The{" "}
        <code>CLAUDE.md</code> in the HQ repo contains the rules:
      </p>

      <ul>
        <li>Never edit code directly in <code>repo/</code></li>
        <li>
          Always create a worktree first, named{" "}
          <code>issue-&lt;N&gt;-&lt;slug&gt;</code>
        </li>
        <li>Fetch and sync before branching</li>
        <li>Clean up worktrees when done</li>
        <li>Push branches, never push to main</li>
      </ul>

      <p>
        Claude Code follows these instructions reliably. It creates worktrees,
        works in them, commits, pushes, opens PRs, and cleans up. The
        &quot;worktree manager&quot; is just a paragraph in a markdown file.
      </p>

      <h2>Shared skills and scripts</h2>

      <p>
        The HQ repo is also where shared automation lives. We have scripts for
        spawning agents into{" "}
        <Link href="https://cmux.dev">cmux</Link> workspaces, waiting for them
        to finish, running review loops, and sending notifications. These
        scripts work across any worktree because they live in the HQ, not in the
        project.
      </p>

      <p>
        Claude Code skills defined in the HQ are available to any task,
        regardless of which worktree the agent is working in. The HQ is the
        shared context that ties everything together.
      </p>

      <h2>How to replicate this</h2>

      <p>
        You don&apos;t need cmux to use this pattern (though it helps for
        running many agents visually). Here&apos;s the minimal setup:
      </p>

      <ol>
        <li>
          Create a new directory and <code>git init</code> it. This is your HQ.
        </li>
        <li>
          Clone your project into <code>repo/</code> inside it.
        </li>
        <li>
          Add a <code>CLAUDE.md</code> to the HQ root with your worktree
          conventions and any cross-repo instructions.
        </li>
        <li>
          Start Claude Code from the HQ directory. Ask it to work on an issue.
          It will create the worktree and do the work there.
        </li>
      </ol>

      <pre>
        <code>{`mkdir my-project-hq && cd my-project-hq
git init
git clone https://github.com/you/your-project repo
mkdir worktrees`}</code>
      </pre>

      <p>
        Add a <code>CLAUDE.md</code> like this:
      </p>

      <pre>
        <code>{`# my-project-hq

- \`repo/\` is the primary checkout (main branch). Never edit it directly.
- \`worktrees/\` contains one worktree per task.

When starting work:
1. cd repo && git fetch origin
2. git worktree add ../worktrees/<branch> -b <branch> origin/main
3. Work in the worktree. Push and PR when done.
4. Clean up: git worktree remove ../worktrees/<branch>`}</code>
      </pre>

      <p>
        That&apos;s it. Claude Code reads the instructions, follows them, and
        you get isolated branches for parallel work with no extra tooling.
      </p>
    </>
  );
}
