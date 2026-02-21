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

        {/* Screenshot */}
        <div data-dev="screenshot" className="mb-12">
          <Image
            src={landingImage}
            alt="cmux terminal app screenshot"
            priority
            placeholder="blur"
            className="w-full rounded-xl border border-border"
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

        {/* Wall of Love */}
        <section data-dev="wall-of-love">
          <h2 className="text-xs font-medium text-muted tracking-tight mb-3">
            Wall of Love
          </h2>
          <div className="columns-1 sm:columns-2 gap-4">
            {testimonials.map((t) => (
              <TestimonialCard key={t.url} testimonial={t} />
            ))}
          </div>
          <div className="mt-2">
            <a
              href="/wall-of-love"
              className="text-sm text-muted hover:text-foreground transition-colors underline underline-offset-2 decoration-border hover:decoration-foreground"
            >
              See all testimonials
            </a>
          </div>
        </section>

      </main>

    </div>
  );
}
