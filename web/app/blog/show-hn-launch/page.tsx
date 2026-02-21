import type { Metadata } from "next";
import Link from "next/link";
import { StaticTweet } from "../../components/static-tweet";

export const metadata: Metadata = {
  title: "cmux Show HN Launch",
  description:
    "How cmux launched on Hacker News, went viral in Japan, and shipped 18 releases in 48 hours.",
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

      <h1>cmux Show HN Launch</h1>
      <time className="text-sm text-muted">February 21, 2026</time>

      <p className="mt-6">
        We launched cmux on{" "}
        <a href="https://news.ycombinator.com/item?id=47079718">Show HN</a>{" "}
        on February 20, 2026. Here&apos;s what happened.
      </p>

      <h2>The problem</h2>
      <p>
        I was running 5+ Claude Code sessions in parallel and kept losing
        track of which ones needed attention. Terminal tabs all looked the
        same. Notifications were generic. Switching between agents meant
        hunting through identical-looking tabs.
      </p>
      <p>
        So I built cmux: a native macOS terminal that puts agent state front
        and center. Vertical sidebar tabs show git branch, working directory,
        listening ports, and the latest notification text for each workspace.
        When an agent needs input, the tab flashes with a colored ring.
      </p>

      <h2>Launch day</h2>
      <p>
        The Show HN post hit the front page. Within hours, Mitchell
        Hashimoto (creator of Ghostty, Vagrant, Terraform) shared it:
      </p>

      <StaticTweet
        name="Mitchell Hashimoto"
        handle="@mitchellh"
        avatar="https://pbs.twimg.com/profile_images/1141762999838842880/64_Y4_XB_400x400.jpg"
        text="Another day another libghostty-based project, this time a macOS terminal with vertical tabs, better organization/notifications, embedded/scriptable browser specifically targeted towards people who use a ton of terminal-based agentic workflows."
        url="https://x.com/mitchellh/status/2024913161238053296"
        date="Feb 20, 2026"
      />

      <p>
        The HN discussion was exactly the kind of feedback you hope for.
        People asked about Ghostty&apos;s relationship to cmux (it uses
        libghostty as a library, not a fork), requested features like pane
        zoom and keyboard customization, and reported bugs. We shipped 18
        releases in the first 48 hours fixing everything we could.
      </p>

      <h2>Viral in Japan</h2>
      <p>
        Something unexpected happened. catnose99, a well-known Japanese
        developer (creator of Zenn and sizu.me), tweeted about cmux and it
        took off in Japan. The tweet got 39K+ views and 800+ likes:
      </p>

      <StaticTweet
        name="catnose"
        handle="@catnose99"
        avatar="https://pbs.twimg.com/profile_images/1831253289780043777/tDKmQSJV_400x400.jpg"
        text={"これ良さそう\n\ncmux.dev\n\nGhosttyベースのターミナルアプリ\nClaude CodeとかのCLIを並行で走らせても迷子になりにくいような工夫がされてる\n入力待ちのパネルが青枠で囲まれたり、独自の通知の仕組みがあったり"}
        url="https://x.com/catnose99/status/2025129675262251026"
        date="Feb 21, 2026"
      />

      <p>
        Rough translation: &quot;This looks good. A Ghostty-based terminal
        app. It&apos;s designed so you don&apos;t easily get lost even when
        running multiple CLI tools like Claude Code in parallel. The
        waiting-for-input panel gets highlighted with a blue frame, and it
        has its own custom notification system.&quot;
      </p>

      <p>
        We didn&apos;t expect international adoption this early. It was a
        reminder that the problem of managing multiple AI agents is universal,
        not just an English-speaking developer thing.
      </p>

      <h2>The socket API in action</h2>
      <p>
        One of the most exciting things to come out of launch was seeing
        people build on top of the cmux socket API. sasha built a pi
        (personal intelligence) extension that hooks into cmux to show
        model info, token usage, and agent state directly in the sidebar:
      </p>

      <StaticTweet
        name="sasha"
        handle="@sasha_computer"
        text={"for my pi folks out there, just spun up a pi-cmux extension that:\n\n- gives cmux notifications context about agent responses\n- shows model, thinking level, token usage, and agent state as status pills in the cmux sidebar\n- gives the LLM tools to drive the browser in cmux, split panes, and control workspaces over the socket"}
        url="https://x.com/sasha_computer/status/2024978414822916358"
        date="Feb 20, 2026"
      />

      <p>
        This is exactly what we hoped for when building the socket API.
        cmux exposes everything over a Unix socket: creating workspaces,
        sending keystrokes, controlling the browser, reading notifications.
        Any tool that can talk to a socket can extend cmux.
      </p>

      <h2>What we learned</h2>
      <ul>
        <li>
          <strong>Ship the socket API early.</strong> The best feedback came
          from people who could actually script cmux and build on top of it.
        </li>
        <li>
          <strong>Fix bugs in public.</strong> Shipping 18 releases in 48
          hours sounds chaotic, but every fix was a direct response to a user
          report. People respected the speed.
        </li>
        <li>
          <strong>The problem is global.</strong> Managing parallel AI agents
          is a pain point everywhere, not just in Silicon Valley.
        </li>
        <li>
          <strong>Use libghostty, not fork Ghostty.</strong> Many people
          assumed cmux was a Ghostty fork. It&apos;s not. It uses libghostty
          as a rendering library, the same way apps use WebKit for web views.
          This distinction matters for trust and for contributing back upstream.
        </li>
      </ul>

      <h2>What&apos;s next</h2>
      <p>
        We&apos;re working on better SSH support for remote containers,
        tmux compatibility layers, and more ways to customize the sidebar.
        If you&apos;re running multiple coding agents and want a terminal
        that keeps up,{" "}
        <a href="https://github.com/manaflow-ai/cmux">give cmux a try</a>.
      </p>
    </>
  );
}
