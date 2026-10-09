import type { Metadata } from "next";
import { CoderouterInstallCommand } from "./install-command";

const tagline =
  "coderouter - route Codex/Claude Code traffic across multiple ChatGPT Pro/Claude Max/OpenCode subscriptions and API keys.";

export const metadata: Metadata = {
  title: "coderouter",
  description: tagline,
  alternates: { canonical: "https://coderouter.dev" },
};

export default function CoderouterLandingPage() {
  return (
    <main className="min-h-screen bg-[#faf9f6] text-[#211f1b]">
      <nav className="mx-auto flex h-16 max-w-2xl items-center justify-between px-6">
        <span className="font-mono text-sm font-medium tracking-[-0.02em]">
          coderouter
        </span>
        <span className="border border-[#d9d2c5] bg-white px-3 py-1 font-mono text-[11px] text-black/50">
          private beta
        </span>
      </nav>

      <section className="mx-auto max-w-2xl px-6 pb-24 pt-20 sm:pt-28">
        <p className="font-mono text-xs tracking-[0.14em] text-[#9a5b22]">
          one endpoint. every subscription.
        </p>
        <h1 className="mt-5 text-balance text-4xl font-medium leading-[1.08] tracking-[-0.045em] sm:text-6xl">
          keep coding when one account runs out.
        </h1>
        <p className="mt-6 max-w-xl text-base leading-7 text-black/55">
          Route Codex traffic across multiple ChatGPT Pro and OpenCode
          subscriptions. Your tools stay the same; coderouter chooses healthy
          capacity.
        </p>

        <CoderouterInstallCommand />

        <div className="mt-14 border-t border-[#d9d2c5]">
          {[
            ["1", "install", "One verified native binary. No daemon."],
            ["2", "connect", "Run cr login, then cr add."],
            ["3", "route", "Use cr codex, cr pi, or cr opencode."],
          ].map(([number, title, body]) => (
            <div
              key={number}
              className="grid grid-cols-[2rem_7rem_1fr] gap-3 border-b border-[#d9d2c5] py-4 text-sm"
            >
              <span className="font-mono text-black/30">{number}</span>
              <strong className="font-medium">{title}</strong>
              <span className="text-black/50">{body}</span>
            </div>
          ))}
        </div>

        <p className="mt-8 font-mono text-[11px] leading-5 text-black/40">
          Codex and OpenCode Go are available now. Pi is experimental. Hosted
          routing requires cmux Pro or Team; self-hosting remains available.
        </p>
      </section>

      <footer className="mx-auto flex h-16 max-w-2xl items-center justify-between border-t border-[#d9d2c5] px-6 font-mono text-[11px] text-black/30">
        <span>coderouter.dev</span>
        <a className="underline underline-offset-4" href="https://cmux.com">
          by cmux
        </a>
      </footer>
    </main>
  );
}
