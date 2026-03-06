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
        cmux intentionally does not have a builtin git worktree manager. cmux
        intentionally has no opinion on worktrees. There are plenty of dedicated
        tools for this:{" "}
        <Link href="https://github.com/d-kuro/gwq">gwq</Link>,{" "}
        <Link href="https://github.com/satococoa/wtp">wtp</Link>,{" "}
        <Link href="https://github.com/max-sixty/worktrunk">worktrunk</Link>,{" "}
        <Link href="https://github.com/coderabbitai/git-worktree-runner">
          git-worktree-runner
        </Link>
        .
      </p>

      <p>
        I personally tried a different approach, which is just putting a few
        paragraphs of instructions in a <code>CLAUDE.md</code>. Claude Code
        handles the rest: creating worktrees, working in them, committing,
        pushing, opening PRs, cleaning up. The worktree manager is just prose.
      </p>

      <h2>What we actually do</h2>

      <p>
        We have a repo called <code>cmuxterm-hq</code> that sits outside the
        cmux source repo. It contains a primary checkout, a folder of worktrees,
        and the <code>CLAUDE.md</code> that tells agents how to use them.
      </p>

      <pre>
        <code>{`cmuxterm-hq/
  repo/               # primary checkout (stays on main, never edited directly)
  worktrees/
    issue-537-notif-crash/
    issue-541-keychain/
    feat-sidebar-ports/
  CLAUDE.md
  scripts/`}</code>
      </pre>

      <p>
        When an agent picks up a task, it creates a worktree off <code>main</code>,
        does the work there, and cleans up when done. Each worktree is a full
        working copy with its own branch, so agents can build and test in
        parallel without conflicts.
      </p>

      <p>
        The HQ being its own repo is nice because you can version your
        automation, scripts, and agent conventions separately from your
        project&apos;s commit history. Skills defined in the HQ are available
        to every agent regardless of which worktree they&apos;re in.
      </p>

      <h2>Multiple codebases</h2>

      <p>
        This also works across repos. If you have an iOS app and a backend in
        separate repos, one HQ can hold both checkouts and a single{" "}
        <code>CLAUDE.md</code> that spans them.
      </p>

      <pre>
        <code>{`my-hq/
  ios-repo/
  backend-repo/
  worktrees/
    ios-issue-42-auth/
    backend-feat-api-v2/
  CLAUDE.md`}</code>
      </pre>

      <p>
        The agent sees one <code>CLAUDE.md</code> that knows about both
        projects, so it can reason across them without you having to merge
        anything into a monorepo.
      </p>

      <h2>Try it</h2>

      <pre>
        <code>{`mkdir my-project-hq && cd my-project-hq
git init
git clone https://github.com/you/your-project repo
mkdir worktrees`}</code>
      </pre>

      <p>
        Add a <code>CLAUDE.md</code>:
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
        Start Claude Code from the HQ directory and ask it to work on something.
        It handles the rest.
      </p>
    </>
  );
}
