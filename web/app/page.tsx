import Image from "next/image";
import Balancer from "react-wrap-balancer";
import { TypingTagline } from "./typing";
import { DownloadButton } from "./components/download-button";
import { GitHubButton } from "./components/github-button";
import { SiteHeader } from "./components/site-header";

const features = [
  {
    title: "Notification rings",
    description:
      "Panes get a blue ring and tabs light up when AI agents need your attention",
    image: "/images/notification-rings.png",
    alt: "Notification rings",
  },
  {
    title: "Notification panel",
    description:
      "See all pending notifications in one place, jump to the most recent unread",
    image: "/images/sidebar-notification-badge.png",
    alt: "Sidebar notification badge",
  },
  {
    title: "In-app browser",
    description:
      "Split a browser alongside your terminal with a scriptable API",
    image: "/images/built-in-browser.png",
    alt: "Built-in browser",
  },
  {
    title: "Vertical + horizontal tabs",
    description:
      "Sidebar shows git branch, working directory, listening ports, and latest notification text. Split horizontally and vertically.",
    image: "/images/vertical-horizontal-tabs-and-splits.png",
    alt: "Vertical tabs and split panes",
  },
];

export default function Home() {
  return (
    <div className="min-h-screen">
      <SiteHeader hideLogo />

      <main className="w-full max-w-3xl mx-auto px-6 py-16 sm:py-24">
        {/* Header */}
        <div className="flex items-center gap-4 mb-10">
          <img
            src="/logo.png"
            alt="cmux icon"
            width={48}
            height={48}
            className="rounded-xl"
          />
          <h1 className="text-2xl font-semibold tracking-tight">cmux</h1>
        </div>

        {/* Tagline */}
        <p className="text-lg leading-relaxed mb-3 text-foreground">
          The terminal built for <TypingTagline />
        </p>
        <p
          className="text-base text-muted"
          style={{ lineHeight: 1.5 }}
        >
          <Balancer>
            Native macOS app built on Ghostty. Vertical tabs, notification rings
            when agents need attention, split panes, and a socket API for
            automation.
          </Balancer>
        </p>

        {/* Download */}
        <div
          className="flex flex-wrap items-center gap-3"
          style={{ marginTop: 21, marginBottom: 33 }}
        >
          <DownloadButton location="hero" />
          <GitHubButton />
        </div>

        {/* Hero screenshot */}
        <Image
          src="/images/main-first-image.png"
          alt="cmux screenshot"
          width={1800}
          height={1100}
          className="rounded-xl border border-border"
          priority
        />

        {/* Features */}
        <section className="mt-16 sm:mt-20">
          <h2 className="text-xs font-medium text-muted tracking-tight mb-8">
            Features
          </h2>
          <div className="space-y-14">
            {features.map((feature) => (
              <div key={feature.title}>
                <h3 className="text-[15px] font-semibold mb-1">
                  {feature.title}
                </h3>
                <p className="text-[15px] text-muted leading-relaxed mb-4">
                  {feature.description}
                </p>
                <Image
                  src={feature.image}
                  alt={feature.alt}
                  width={1200}
                  height={750}
                  className="rounded-lg border border-border"
                />
              </div>
            ))}
          </div>

          {/* Extra features — plain list */}
          <ul className="mt-10 space-y-3 text-[15px]" style={{ lineHeight: 1.275 }}>
            <li className="flex gap-3">
              <span className="text-muted shrink-0">-</span>
              <span>
                <strong className="font-medium">Scriptable</strong>
                <span className="text-muted">
                  : CLI and socket API to create workspaces, split panes, send
                  keystrokes, and automate the browser
                </span>
              </span>
            </li>
            <li className="flex gap-3">
              <span className="text-muted shrink-0">-</span>
              <span>
                <strong className="font-medium">Native macOS app</strong>
                <span className="text-muted">
                  : built with Swift and AppKit, not Electron. Fast startup, low
                  memory.
                </span>
              </span>
            </li>
            <li className="flex gap-3">
              <span className="text-muted shrink-0">-</span>
              <span>
                <strong className="font-medium">Ghostty compatible</strong>
                <span className="text-muted">
                  : reads your existing ~/.config/ghostty/config for themes,
                  fonts, and colors
                </span>
              </span>
            </li>
            <li className="flex gap-3">
              <span className="text-muted shrink-0">-</span>
              <span>
                <strong className="font-medium">GPU-accelerated</strong>
                <span className="text-muted">
                  : powered by libghostty for smooth rendering
                </span>
              </span>
            </li>
            <li className="flex gap-3">
              <span className="text-muted shrink-0">-</span>
              <span>
                <strong className="font-medium">Keyboard shortcuts</strong>
                <span className="text-muted">
                  :{" "}
                  <a
                    href="/docs/keyboard-shortcuts"
                    className="underline underline-offset-2 decoration-border hover:decoration-foreground transition-colors"
                  >
                    extensive shortcuts
                  </a>{" "}
                  for workspaces, splits, browser, and more
                </span>
              </span>
            </li>
          </ul>
        </section>

        {/* Install */}
        <section className="mt-16 sm:mt-20">
          <h2 className="text-xs font-medium text-muted tracking-tight mb-6">
            Install
          </h2>

          <h3 className="text-[15px] font-semibold mb-2">
            DMG (recommended)
          </h3>
          <p className="text-[15px] text-muted leading-relaxed mb-4">
            Open the .dmg and drag cmux to your Applications folder. cmux
            auto-updates via Sparkle, so you only need to download once.
          </p>
          <div className="mb-8">
            <DownloadButton location="install" size="sm" />
          </div>

          <h3 className="text-[15px] font-semibold mb-2">Homebrew</h3>
          <pre className="bg-code-bg rounded-md p-4 text-sm font-mono overflow-x-auto mb-3">
            <code>{`brew tap manaflow-ai/cmux\nbrew install --cask cmux`}</code>
          </pre>
          <p className="text-[15px] text-muted leading-relaxed">
            To update later:{" "}
            <code className="text-xs bg-code-bg px-1.5 py-0.5 rounded">
              brew upgrade --cask cmux
            </code>
          </p>
        </section>

        {/* Why cmux */}
        <section className="mt-16 sm:mt-20">
          <h2 className="text-xs font-medium text-muted tracking-tight mb-6">
            Why cmux?
          </h2>
          <div className="space-y-4 text-[15px] text-muted leading-relaxed">
            <p>
              I run a lot of Claude Code and Codex sessions in parallel. I was
              using Ghostty with split panes, relying on native macOS
              notifications to know when an agent needed me. But the notification
              body is always just &ldquo;waiting for your input&rdquo; with no
              context, and with enough tabs open I couldn&rsquo;t even read the
              titles anymore.
            </p>
            <p>
              I tried a few coding orchestrators but most were Electron/Tauri
              apps and the performance bugged me. I also prefer the terminal
              since GUI orchestrators lock you into their workflow. So I built
              cmux as a native macOS app in Swift/AppKit. It uses libghostty for
              terminal rendering and reads your existing Ghostty config.
            </p>
            <p>
              The main additions are the sidebar and notification system. When an
              agent is waiting, its pane gets a blue ring and the tab lights up
              in the sidebar, so I can tell which one needs me across splits and
              tabs. Everything is scriptable through the CLI and socket API.
            </p>
          </div>
        </section>
      </main>
    </div>
  );
}
