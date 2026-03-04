import type { Metadata } from "next";
import Link from "next/link";

export const metadata: Metadata = {
  title: "Cmd+Shift+U",
  description:
    "How Cmd+Shift+U navigates between finished agents across workspaces in cmux.",
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
    title: "Cmd+Shift+U",
    description:
      "How Cmd+Shift+U navigates between finished agents across workspaces in cmux.",
    type: "article",
    publishedTime: "2026-03-04T00:00:00Z",
    url: "https://cmux.dev/blog/cmd-shift-u",
  },
  twitter: {
    card: "summary",
    title: "Cmd+Shift+U",
    description:
      "How Cmd+Shift+U navigates between finished agents across workspaces in cmux.",
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

      <h1>Cmd+Shift+U</h1>
      <time dateTime="2026-03-04" className="text-sm text-muted">
        March 4, 2026
      </time>

      <p className="mt-6">
        My favorite cmux feature is <kbd>Cmd+Shift+U</kbd>. I usually have
        4-8 agents running at once, and finished tasks get buried. I used to
        click through tabs to find what just completed. That broke my focus
        and I still missed things that finished minutes ago.
      </p>

      {/* TODO: add showcase video here */}

      <p>
        <kbd>Cmd+Shift+U</kbd> jumps to the newest unread notification. In
        practice that means the last agent that finished. It switches to the
        right workspace, focuses the exact pane, flashes it so you see where
        to look, and marks it read. If the notification came from another
        window, that window comes forward.
      </p>

      <p>
        Agents trigger{" "}
        <Link href="/docs/notifications">notifications</Link> through OSC
        sequences, CLI hooks, or <code>cmux notify</code> when they complete
        a task. Each notification is tied to a workspace and surface.{" "}
        <kbd>Cmd+Shift+U</kbd> just finds the newest unread one and takes you
        there.
      </p>

      <p>
        I use it like an inbox for agent completions. Press the shortcut, read
        the result, move on. I press it probably 30-40 times on a busy day.
      </p>
    </>
  );
}
