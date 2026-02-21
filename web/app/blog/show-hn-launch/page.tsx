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
        We posted cmux on{" "}
        <a href="https://news.ycombinator.com/item?id=47079718">Show HN</a>{" "}
        on Feb 19:
      </p>

      <blockquote className="border-l-2 border-border pl-4 my-6 text-muted space-y-3 text-[15px]">
        <p>
          I run a lot of Claude Code and Codex sessions in parallel. I was using
          Ghostty with a bunch of split panes, and relying on native macOS
          notifications to know when an agent needed me. But Claude Code&apos;s
          notification body is always just &quot;Claude is waiting for your
          input&quot; with no context, and with enough tabs open, I couldn&apos;t
          even read the titles anymore.
        </p>
        <p>
          I tried a few coding orchestrators but most of them were Electron/Tauri
          apps and the performance bugged me. I also just prefer the terminal
          since GUI orchestrators lock you into their workflow. So I built cmux as
          a native macOS app in Swift/AppKit. It uses libghostty for terminal
          rendering and reads your existing Ghostty config for themes, fonts,
          colors, and more.
        </p>
        <p>
          The main additions are the sidebar and notification system. The sidebar
          has vertical tabs that show git branch, working directory, listening
          ports, and the latest notification text for each workspace. The
          notification system picks up terminal sequences (OSC 9/99/777) and has a
          CLI (cmux notify) you can wire into agent hooks for Claude Code,
          OpenCode, etc. When an agent is waiting, its pane gets a blue ring and
          the tab lights up in the sidebar, so I can tell which one needs me
          across splits and tabs. Cmd+Shift+U jumps to the most recent unread.
        </p>
        <p>
          The in-app browser has a scriptable API. Agents can snapshot the
          accessibility tree, get element refs, click, fill forms, evaluate JS,
          and read console logs. You can split a browser pane next to your
          terminal and have Claude Code interact with your dev server directly.
        </p>
        <p>
          Everything is scriptable through the CLI and socket API: create
          workspaces/tabs, split panes, send keystrokes, open URLs in the browser.
        </p>
      </blockquote>

      <p>
        It hit the front page. Mitchell Hashimoto shared it:
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
        Another exciting thing was seeing people build on top of the socket
        API. sasha built a pi-cmux extension that shows model info, token
        usage, and agent state in the sidebar:
      </p>

      <Tweet id="2024978414822916358" />

      <p>
        cmux exposes everything over a Unix socket: creating workspaces,
        sending keystrokes, controlling the browser, reading notifications.
        The cmux CLI talks to this socket, and most people should just use
        the CLI. But the socket is there if you need it.
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
