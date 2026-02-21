import Image from "next/image";
import Balancer from "react-wrap-balancer";
import landingImage from "./assets/landing-image.png";
import { TypingTagline } from "./typing";
import { DownloadButton } from "./components/download-button";
import { GitHubButton } from "./components/github-button";
import { SiteHeader } from "./components/site-header";
import { testimonials, TestimonialCard } from "./testimonials";

export default function Home() {
  return (
    <div className="min-h-screen">
      <SiteHeader hideLogo />

      <main className="w-full max-w-2xl mx-auto px-6 py-16 sm:py-24">
        {/* Header */}
        <div className="flex items-center gap-4 mb-10" data-dev="header">
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
        <p className="text-base text-muted" data-dev="subtitle" style={{ lineHeight: 1.5 }}>
          <Balancer>
            Native macOS app built on Ghostty. Vertical tabs, notification rings
            when agents need attention, split panes, and a socket API for
            automation.
          </Balancer>
        </p>

        {/* Download */}
        <div className="flex flex-wrap items-center gap-3" data-dev="download" style={{ marginTop: 21, marginBottom: 33 }}>
          <DownloadButton location="hero" />
          <GitHubButton />
        </div>

        {/* Screenshot — break out of max-w-2xl to be wider */}
        <div data-dev="screenshot" className="mb-12 -mx-6 sm:-mx-24 md:-mx-40 lg:-mx-72 xl:-mx-96">
          <Image
            src={landingImage}
            alt="cmux terminal app screenshot"
            priority
            placeholder="blur"
            className="w-full rounded-xl"
          />
        </div>

        {/* Features */}
        <section data-dev="features">
          <h2 className="text-xs font-medium text-muted tracking-tight mb-3">
            Features
          </h2>
          <ul className="space-y-3 text-[15px]" data-dev="features-ul" style={{ lineHeight: 1.275 }}>
            <li className="flex gap-3">
              <span className="text-muted shrink-0">-</span>
              <span>
                <strong className="font-medium">Notification rings</strong>
                <span className="text-muted">
                  : tabs flash when agents need your input
                </span>
              </span>
            </li>
            <li className="flex gap-3">
              <span className="text-muted shrink-0">-</span>
              <span>
                <strong className="font-medium">Vertical tabs</strong>
                <span className="text-muted">
                  : see all your terminals at a glance in a sidebar
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
                <strong className="font-medium">Split panes</strong>
                <span className="text-muted">
                  : horizontal and vertical splits within each tab
                </span>
              </span>
            </li>
            <li className="flex gap-3">
              <span className="text-muted shrink-0">-</span>
              <span>
                <strong className="font-medium">Socket API</strong>
                <span className="text-muted">
                  : programmatic control for creating tabs, sending input
                </span>
              </span>
            </li>
            <li className="flex gap-3">
              <span className="text-muted shrink-0">-</span>
              <span>
                <strong className="font-medium">Lightweight</strong>
                <span className="text-muted">
                  : native Swift + AppKit, no Electron
                </span>
              </span>
            </li>
            <li className="flex gap-3">
              <span className="text-muted shrink-0">-</span>
              <span>
                <strong className="font-medium">Keyboard shortcuts</strong>
                <span className="text-muted">
                  : <a href="/docs/keyboard-shortcuts" className="underline underline-offset-2 decoration-border hover:decoration-foreground transition-colors">extensive shortcuts</a> for workspaces, splits, browser, and more
                </span>
              </span>
            </li>
          </ul>
          <div data-dev="features-spacer" style={{ height: 23 }} />
        </section>

        {/* Wall of Love — break out wider */}
        <section data-dev="wall-of-love" className="-mx-6 sm:-mx-24 md:-mx-40 mb-10">
          <div className="columns-1 sm:columns-2 lg:columns-3 gap-4 px-6 sm:px-8">
            {testimonials.map((t) => (
              <TestimonialCard key={t.url} testimonial={t} />
            ))}
          </div>
        </section>

        {/* FAQ */}
        <section data-dev="faq">
          <h2 className="text-xs font-medium text-muted tracking-tight mb-3">
            FAQ
          </h2>
          <div className="space-y-5 text-[15px]" style={{ lineHeight: 1.5 }}>
            <div>
              <p className="font-medium mb-1">How does cmux relate to Ghostty?</p>
              <p className="text-muted">
                cmux is not a fork of Ghostty. It uses{" "}
                <a href="https://github.com/ghostty-org/ghostty" className="underline underline-offset-2 decoration-border hover:decoration-foreground transition-colors">libghostty</a>{" "}
                as a library for terminal rendering, the same way apps use WebKit for web views.
                Ghostty is a standalone terminal; cmux is a different app built on top of its rendering engine.
              </p>
            </div>
            <div>
              <p className="font-medium mb-1">What platforms does it support?</p>
              <p className="text-muted">
                macOS only, for now. cmux is a native Swift + AppKit app.
              </p>
            </div>
            <div>
              <p className="font-medium mb-1">What coding agents does cmux work with?</p>
              <p className="text-muted">
                Yes. The notification system uses standard terminal escape sequences (OSC 9/99/777),
                so any CLI tool that prints those will trigger notification rings. The socket API and
                CLI work with any process. People use cmux with Claude Code, Gemini CLI, Codex, Aider,
                and other agents.
              </p>
            </div>
            <div>
              <p className="font-medium mb-1">Can I customize keyboard shortcuts?</p>
              <p className="text-muted">
                cmux reads keybindings from Ghostty config files (<code className="text-xs bg-code-bg px-1.5 py-0.5 rounded">~/.config/ghostty/config</code>).
                See the{" "}
                <a href="/docs/configuration" className="underline underline-offset-2 decoration-border hover:decoration-foreground transition-colors">configuration docs</a>{" "}
                for details.
              </p>
            </div>
            <div>
              <p className="font-medium mb-1">How do notification rings work?</p>
              <p className="text-muted">
                When an agent needs your attention, the tab flashes with a colored ring. Notifications
                fire via OSC escape sequences, the cmux CLI, or{" "}
                <a href="/docs/notifications" className="underline underline-offset-2 decoration-border hover:decoration-foreground transition-colors">Claude Code hooks</a>.
                You also get a macOS desktop notification.
              </p>
            </div>
            <div>
              <p className="font-medium mb-1">How does it compare to tmux?</p>
              <p className="text-muted">
                tmux is a terminal multiplexer that runs inside any terminal. cmux is a native macOS app
                with a GUI — vertical tabs, split panes, an embedded browser, and a socket API are all
                built in. No config files or prefix keys needed.
              </p>
            </div>
            <div>
              <p className="font-medium mb-1">Is cmux free?</p>
              <p className="text-muted">
                Yes, cmux is free to use. The source code is available on{" "}
                <a href="https://github.com/manaflow-ai/cmux" className="underline underline-offset-2 decoration-border hover:decoration-foreground transition-colors">GitHub</a>.
              </p>
            </div>
          </div>
        </section>

      </main>

    </div>
  );
}
