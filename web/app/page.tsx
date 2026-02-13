import Balancer from "react-wrap-balancer";
import { TypingTagline } from "./typing";
import { DownloadButton } from "./components/download-button";
import { SiteHeader } from "./components/site-header";

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
          <DownloadButton />
          <a
            href="https://github.com/manaflow-ai/cmux"
            target="_blank"
            rel="noopener noreferrer"
            className="inline-flex items-center whitespace-nowrap gap-2 rounded-full border border-border px-5 py-2.5 text-[15px] font-medium text-foreground hover:bg-code-bg transition-colors"
          >
            <svg width="16" height="16" viewBox="0 0 24 24" fill="currentColor">
              <path d="M12 0c-6.626 0-12 5.373-12 12 0 5.302 3.438 9.8 8.207 11.387.599.111.793-.261.793-.577v-2.234c-3.338.726-4.033-1.416-4.033-1.416-.546-1.387-1.333-1.756-1.333-1.756-1.089-.745.083-.729.083-.729 1.205.084 1.839 1.237 1.839 1.237 1.07 1.834 2.807 1.304 3.492.997.107-.775.418-1.305.762-1.604-2.665-.305-5.467-1.334-5.467-5.931 0-1.311.469-2.381 1.236-3.221-.124-.303-.535-1.524.117-3.176 0 0 1.008-.322 3.301 1.23.957-.266 1.983-.399 3.003-.404 1.02.005 2.047.138 3.006.404 2.291-1.552 3.297-1.23 3.297-1.23.653 1.653.242 2.874.118 3.176.77.84 1.235 1.911 1.235 3.221 0 4.609-2.807 5.624-5.479 5.921.43.372.823 1.102.823 2.222v3.293c0 .319.192.694.801.576 4.765-1.589 8.199-6.086 8.199-11.386 0-6.627-5.373-12-12-12z" />
            </svg>
            View on GitHub
          </a>
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

      </main>

    </div>
  );
}
