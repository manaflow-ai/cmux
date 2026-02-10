import Image from "next/image";
import { TypingTagline } from "./typing";
import { ThemeToggle } from "./theme";


export default function Home() {
  return (
    <div className="flex min-h-screen justify-center px-6 py-20 sm:py-32">
      {/* Theme toggle */}
      <div className="fixed top-5 right-5">
        <ThemeToggle />
      </div>

      <main className="w-full max-w-xl">
        {/* Header */}
        <div className="flex items-center gap-4 mb-10">
          <Image
            src="/icon.png"
            alt="cmux icon"
            width={48}
            height={48}
            className="rounded-xl"
            priority
          />
          <h1 className="text-2xl font-semibold tracking-tight">cmux</h1>
        </div>

        {/* Tagline */}
        <p className="text-lg leading-relaxed mb-3 text-foreground">
          A terminal built for <TypingTagline />
        </p>
        <p className="text-base leading-relaxed text-muted mb-12">
          Native macOS app built on Ghostty. Vertical tabs, notification rings
          when agents need attention, split panes, and a socket API for
          automation.
        </p>

        {/* Download */}
        <div className="mb-12">
          <a
            href="https://github.com/manaflow-ai/cmux/releases/latest/download/cmux-macos.dmg"
            className="inline-flex items-center gap-2.5 rounded-full border border-border bg-background px-5 py-2.5 text-[15px] font-medium text-foreground hover:bg-code-bg transition-colors"
          >
            <svg width="16" height="19" viewBox="0 0 814 1000" fill="currentColor">
              <path d="M788.1 340.9c-5.8 4.5-108.2 62.2-108.2 190.5 0 148.4 130.3 200.9 134.2 202.2-.6 3.2-20.7 71.9-68.7 141.9-42.8 61.6-87.5 123.1-155.5 123.1s-85.5-39.5-164-39.5c-76.5 0-103.7 40.8-165.9 40.8s-105.6-57.8-155.5-127.4c-58.3-81.6-105.6-208.4-105.6-328.6 0-193 125.6-295.5 249.2-295.5 65.7 0 120.5 43.1 161.7 43.1 39.2 0 100.4-45.8 175.1-45.8 28.3 0 130.3 2.6 197.2 99.2zM554.1 159.4c31.1-36.9 53.1-88.1 53.1-139.3 0-7.1-.6-14.3-1.9-20.1-50.6 1.9-110.8 33.7-147.1 75.8-28.9 32.4-57.2 83.6-57.2 135.4 0 7.8 1.3 15.6 1.9 18.1 3.2.6 8.4 1.3 13.6 1.3 45.4 0 102.5-30.4 137.6-71.2z" />
            </svg>
            Download for Mac
          </a>
        </div>

        {/* Features */}
        <section className="mb-12">
          <h2 className="text-xs font-medium text-muted tracking-wider mb-3">
            Features
          </h2>
          <ul className="space-y-3 text-[15px] leading-relaxed">
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
          </ul>
        </section>

        {/* Footer */}
        <footer className="flex items-center gap-4 text-sm text-muted pt-4 border-t border-border">
          <a
            href="https://github.com/manaflow-ai/cmux"
            className="hover:text-foreground transition-colors"
          >
            GitHub
          </a>
          <a
            href="https://cmux.term.sh"
            className="hover:text-foreground transition-colors"
          >
            Docs
          </a>
        </footer>
      </main>
    </div>
  );
}
