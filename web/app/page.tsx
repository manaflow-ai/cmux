import { FadeImage } from "./components/fade-image";
import Balancer from "react-wrap-balancer";
import landingImage from "./assets/landing-image.png";
import { TypingTagline } from "./typing";
import { DownloadButton } from "./components/download-button";
import { GitHubButton } from "./components/github-button";
import { SiteHeader } from "./components/site-header";
import { testimonials } from "./testimonials";

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
        <div className="flex flex-wrap items-center gap-3" data-dev="download" style={{ marginTop: 21, marginBottom: 16 }}>
          <DownloadButton location="hero" />
          <GitHubButton />
        </div>

        {/* Features */}
        <section data-dev="features" style={{ paddingTop: 12, paddingBottom: 15 }}>
          <h2 className="text-xs font-medium text-muted tracking-tight mb-3">
            Features
          </h2>
          <ul className="space-y-3 text-[15px]" data-dev="features-ul" style={{ lineHeight: 1.275 }}>
            <li className="flex gap-3">
              <span className="text-muted shrink-0">-</span>
              <span>
                <strong className="font-medium">Vertical tabs</strong>
                <span className="text-muted">
                  : sidebar shows git branch, working directory, ports, and notification text
                </span>
              </span>
            </li>
            <li className="flex gap-3">
              <span className="text-muted shrink-0">-</span>
              <span>
                <strong className="font-medium">Notification rings</strong>
                <span className="text-muted">
                  : panes light up when agents need attention
                </span>
              </span>
            </li>

            <li className="flex gap-3">
              <span className="text-muted shrink-0">-</span>
              <span>
                <strong className="font-medium">In-app browser</strong>
                <span className="text-muted">
                  : split a browser alongside your terminal with a scriptable API
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
                <strong className="font-medium">Scriptable</strong>
                <span className="text-muted">
                  : CLI and socket API for automation and scripting
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
        </section>

        {/* Screenshot - break out of max-w-2xl to be wider */}
        <div data-dev="screenshot" className="mb-12 -mx-6 sm:-mx-24 md:-mx-40 lg:-mx-72 xl:-mx-96">
          <FadeImage
            src={landingImage}
            alt="cmux terminal app screenshot"
            priority
            className="w-full rounded-xl"
          />
        </div>

        {/* FAQ */}
        <div data-dev="faq-top-spacer" style={{ height: 0 }} />
        <section data-dev="faq" className="mb-10">
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
                All of them. cmux is a terminal, so any agent that runs in a terminal works out of the
                box: Claude Code, Codex, OpenCode, Gemini CLI, Kiro, Aider, Goose, Amp, Cline,
                Cursor Agent, and anything else you can launch from the command line.
              </p>
            </div>
            <div>
              <p className="font-medium mb-1">How do notifications work?</p>
              <p className="text-muted">
                When a process needs attention, cmux shows notification rings around panes,
                unread badges in the sidebar, a notification popover, and a macOS desktop
                notification. These fire automatically via standard terminal escape sequences
                (OSC 9/99/777), or you can trigger them with the{" "}
                <a href="/docs/notifications" className="underline underline-offset-2 decoration-border hover:decoration-foreground transition-colors">cmux CLI</a>{" "}
                and{" "}
                <a href="/docs/notifications" className="underline underline-offset-2 decoration-border hover:decoration-foreground transition-colors">Claude Code hooks</a>.
              </p>
            </div>
            <div>
              <p className="font-medium mb-1">Can I customize keyboard shortcuts?</p>
              <p className="text-muted">
                Terminal keybindings are read from your Ghostty config
                file (<code className="text-xs bg-code-bg px-1.5 py-0.5 rounded">~/.config/ghostty/config</code>).
                cmux-specific shortcuts (workspaces, splits, browser, notifications) can be
                customized in Settings. See the{" "}
                <a href="/docs/keyboard-shortcuts" className="underline underline-offset-2 decoration-border hover:decoration-foreground transition-colors">default shortcuts</a>{" "}
                for a full list.
              </p>
            </div>
            <div>
              <p className="font-medium mb-1">How does it compare to tmux?</p>
              <p className="text-muted">
                tmux is a terminal multiplexer that runs inside any terminal. cmux is a native macOS app
                with a GUI: vertical tabs, split panes, an embedded browser, and a socket API are all
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

        {/* Community */}
        <section data-dev="community" className="mb-10">
          <h2 className="text-xs font-medium text-muted tracking-tight mb-3">
            Community
          </h2>
          <ul data-dev="community-ul" className="text-[15px]" style={{ lineHeight: 1.5, display: "flex", flexDirection: "column", gap: 16 }}>
            {testimonials.map((t) => (
              <li key={t.url}>
                <span>
                  <a
                    href={t.url}
                    target="_blank"
                    rel="noopener noreferrer"
                    className="group"
                  >
                    <span className="text-muted group-hover:text-foreground transition-colors">
                      &quot;{t.text}&quot;
                    </span>
                    {"translation" in t && t.translation && (
                      <span className="text-muted/60 text-xs italic"> — {t.translation}</span>
                    )}
                  </a>
                  {" "}
                  <a
                    href={t.url}
                    target="_blank"
                    rel="noopener noreferrer"
                    className="inline-flex items-center gap-1 text-muted hover:text-foreground transition-colors"
                  >
                    —
                    {t.avatar && (
                      <img
                        src={t.avatar}
                        alt={t.name}
                        width={16}
                        height={16}
                        className="rounded-full inline-block"
                      />
                    )}
                    {t.name}{"subtitle" in t && t.subtitle ? `, ${t.subtitle}` : ""}
                  </a>
                </span>
              </li>
            ))}
          </ul>
        </section>

        {/* Bottom CTA */}
        <div className="flex flex-wrap items-center justify-center gap-3 mt-12">
          <DownloadButton location="bottom" />
          <GitHubButton />
        </div>
        <div className="flex justify-center mt-6">
          <a
            href="/docs"
            className="text-sm text-muted hover:text-foreground transition-colors underline underline-offset-2 decoration-border hover:decoration-foreground"
          >
            Read the Docs
          </a>
        </div>

      </main>

    </div>
  );
}
