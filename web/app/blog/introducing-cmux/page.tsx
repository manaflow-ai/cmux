import type { Metadata } from "next";
import Link from "next/link";

export const metadata: Metadata = {
  title: "Introducing cmux",
  description:
    "A native macOS terminal built on Ghostty, designed for running multiple AI coding agents side by side.",
};

export default function IntroducingCmuxPage() {
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

      <h1>Introducing cmux</h1>
      <time className="text-sm text-muted">February 12, 2026</time>

      <p className="mt-6">
        cmux is a native macOS terminal application built on top of Ghostty,
        designed from the ground up for developers who run multiple AI coding
        agents simultaneously.
      </p>

      <h2>Why cmux?</h2>
      <p>
        Modern development workflows often involve running several agents at
        once. Claude Code, Codex, and other tools each in their own
        terminal. Keeping track of which ones need attention and switching
        between them quickly is the problem cmux solves.
      </p>

      <h2>Key features</h2>
      <ul>
        <li>
          <strong>Vertical tabs</strong> : see all your terminals at a
          glance in a sidebar
        </li>
        <li>
          <strong>Notification rings</strong> : tabs flash when an agent
          needs your input
        </li>
        <li>
          <strong>Split panes</strong> : horizontal and vertical splits
          within each workspace
        </li>
        <li>
          <strong>Socket API</strong> : programmatic control for creating
          tabs and sending input
        </li>
        <li>
          <strong>GPU-accelerated</strong> : powered by libghostty for
          smooth rendering
        </li>
      </ul>

      <h2>Get started</h2>
      <p>
        Install cmux via Homebrew or download the DMG from the{" "}
        <Link href="/docs/getting-started">getting started guide</Link>.
      </p>
    </>
  );
}
