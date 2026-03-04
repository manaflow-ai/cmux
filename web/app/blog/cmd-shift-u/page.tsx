import type { Metadata } from "next";
import Link from "next/link";

export const metadata: Metadata = {
  title: "My Favorite Feature: Cmd+Shift+U",
  description:
    "The single keyboard shortcut that changed how I work with AI coding agents.",
  keywords: [
    "cmux",
    "terminal",
    "macOS",
    "notifications",
    "AI coding agents",
    "keyboard shortcuts",
    "developer tools",
    "workflow",
  ],
  openGraph: {
    title: "My Favorite Feature: Cmd+Shift+U",
    description:
      "The single keyboard shortcut that changed how I work with AI coding agents.",
    type: "article",
    publishedTime: "2026-03-04T00:00:00Z",
    url: "https://cmux.dev/blog/cmd-shift-u",
  },
  twitter: {
    card: "summary",
    title: "My Favorite Feature: Cmd+Shift+U",
    description:
      "The single keyboard shortcut that changed how I work with AI coding agents.",
  },
  alternates: {
    canonical: "https://cmux.dev/blog/cmd-shift-u",
  },
};

export default function CmdShiftUPage() {
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

      <h1>My Favorite Feature: Cmd+Shift+U</h1>
      <time dateTime="2026-03-04" className="text-sm text-muted">
        March 4, 2026
      </time>

      <p className="mt-6">
        People assume my favorite cmux feature is vertical tabs. It&apos;s not.
        It&apos;s <kbd>Cmd+Shift+U</kbd>.
      </p>

      <p>
        When you run multiple AI coding agents across different workspaces,
        you lose track of which ones are done. Maybe Codex finished fixing
        that bug in workspace 3. Maybe Claude wrapped up the refactor in
        workspace 7. You don&apos;t know until you click through each tab
        and check.
      </p>

      <p>
        <kbd>Cmd+Shift+U</kbd> fixes this. It jumps you to the latest unread
        notification, which means the most recent agent that just finished
        its task. One keystroke and you&apos;re looking at the result. No
        hunting, no tab scanning, no context lost trying to remember which
        workspace was which.
      </p>

      {/* TODO: add showcase video here */}

      <p>
        The way it works: cmux has a{" "}
        <Link href="/docs/notifications">notification system</Link> that
        agents can fire through OSC sequences, CLI hooks, or the{" "}
        <code>cmux notify</code> command. When an agent completes a task,
        it sends a notification tied to its workspace and surface.{" "}
        <kbd>Cmd+Shift+U</kbd> finds the newest unread one, switches to that
        workspace, focuses the exact pane, flashes it so your eyes land on
        it, and marks it as read. If the notification came from a different
        window, it brings that window forward too.
      </p>

      <p>
        It turns a multi-agent workflow from &quot;check on things
        periodically&quot; into &quot;get pulled to the right place at the
        right time.&quot; I hit it dozens of times a day without thinking
        about it. The best features are the ones that disappear into muscle
        memory.
      </p>
    </>
  );
}
