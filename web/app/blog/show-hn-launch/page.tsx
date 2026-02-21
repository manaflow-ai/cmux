import type { Metadata } from "next";
import Link from "next/link";
import { Tweet } from "react-tweet";

export const metadata: Metadata = {
  title: "Launching cmux on Show HN",
  description:
    "cmux launched on Hacker News, hit the front page, went viral in Japan, and shipped 18 releases in 48 hours. Here's what happened.",
  keywords: [
    "cmux",
    "Show HN",
    "Hacker News",
    "terminal",
    "macOS",
    "Ghostty",
    "libghostty",
    "AI coding agents",
    "Claude Code",
    "launch",
  ],
  openGraph: {
    title: "Launching cmux on Show HN",
    description:
      "cmux launched on Hacker News, hit the front page, went viral in Japan, and shipped 18 releases in 48 hours.",
    type: "article",
    publishedTime: "2026-02-21T00:00:00Z",
  },
};

export default function ShowHNLaunchPage() {
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

      <h1>Launching cmux on Show HN</h1>
      <time className="text-sm text-muted">February 21, 2026</time>

      <p className="mt-6">
        I was running 5+ Claude Code sessions in parallel and kept losing
        track of which ones needed attention. Terminal tabs all looked the
        same. Switching between agents meant hunting through identical windows.
      </p>

      <p>
        So I built{" "}
        <a href="https://github.com/manaflow-ai/cmux">cmux</a>: a native
        macOS terminal on top of{" "}
        <a href="https://github.com/ghostty-org/ghostty">libghostty</a> that
        puts agent state front and center. Vertical sidebar tabs show git
        branch, working directory, and listening ports. When an agent needs
        input, the tab flashes with a colored ring.
      </p>

      <p>
        We posted it on{" "}
        <a href="https://news.ycombinator.com/item?id=47079718">Show HN</a>{" "}
        and it hit the front page. Mitchell Hashimoto shared it:
      </p>

      <Tweet id="2024913161238053296" />

      <p>
        The HN thread was good feedback. People asked about the Ghostty
        relationship (cmux uses libghostty as a library, not a fork),
        requested features, and reported bugs. We shipped 18 releases in 48
        hours fixing everything we could.
      </p>

      <p>
        Surprisingly, cmux went semi-viral in Japan!
      </p>

      <Tweet id="2025129675262251026" />

      <p>
        Translation: &quot;This looks good. A Ghostty-based terminal app
        designed so you don&apos;t get lost running multiple CLIs like Claude
        Code in parallel. The waiting-for-input panel gets a blue frame, and
        it has its own notification system.&quot;
      </p>

      <p>
        We didn&apos;t expect international adoption this early. Turns out
        managing parallel AI agents is a universal pain point.
      </p>

      <p>
        The most exciting thing was seeing people build on top of the socket
        API. sasha built a pi-cmux extension that shows model info, token
        usage, and agent state in the sidebar:
      </p>

      <Tweet id="2024978414822916358" />

      <p>
        cmux exposes everything over a Unix socket: creating workspaces,
        sending keystrokes, controlling the browser, reading notifications.
        Any tool that can talk to a socket can extend it. That&apos;s the
        whole point.
      </p>

      <p>
        Three things I&apos;d tell someone doing a Show HN. Ship the
        programmable API early, because the best feedback comes from people
        who can actually build on your thing. Fix bugs in public, because 18
        releases in 48 hours sounds chaotic but people respect the speed. And
        don&apos;t assume your problem is local. We built cmux for our own
        workflow and it resonated in Tokyo the same day it resonated in San
        Francisco.
      </p>

      <p>
        If you&apos;re running multiple coding agents and want a terminal
        that keeps up,{" "}
        <a href="https://github.com/manaflow-ai/cmux">try cmux</a>.
      </p>
    </>
  );
}
