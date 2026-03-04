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
        My favorite cmux feature is <kbd>Cmd+Shift+U</kbd>. I have 17
        workspaces open right now, each running an agent. I used to click
        through tabs and the notification panel to figure out what completed.
        Typing is faster.
      </p>

      <video
        src="/blog/cmd-shift-u.mp4"
        width={1824}
        height={1080}
        autoPlay
        loop
        muted
        playsInline
        className="my-6 rounded-lg w-full h-auto"
      />

      <p>
        <kbd>Cmd+Shift+U</kbd> jumps to the newest unread{" "}
        <Link href="/docs/notifications">notification</Link>. In practice
        that means the last agent that finished. It switches to the right
        workspace, focuses the exact pane, flashes it so you see where to
        look, and marks it read. If the notification came from another window,
        that window comes forward.
      </p>
    </>
  );
}
