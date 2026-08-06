import type { Metadata } from "next";

const tagline =
  "coderouter - route Codex/Claude Code traffic across multiple ChatGPT Pro/Claude Max/OpenCode subscriptions and API keys.";

export const metadata: Metadata = {
  title: "coderouter",
  description: tagline,
  alternates: { canonical: "https://coderouter.dev" },
};

export default function CoderouterLandingPage() {
  return (
    <main className="min-h-screen bg-[#fafafa] text-[#111]">
      <nav className="mx-auto flex h-16 max-w-6xl items-center justify-between px-6">
        <span className="font-mono text-sm font-medium tracking-[-0.02em]">
          coderouter
        </span>
        <span className="rounded-full border border-black/10 bg-white px-3 py-1 font-mono text-[11px] text-black/50">
          private beta
        </span>
      </nav>

      <section className="mx-auto flex min-h-[calc(100vh-8rem)] max-w-6xl items-center px-6 py-20">
        <div className="max-w-4xl">
          <p className="mb-6 font-mono text-xs uppercase tracking-[0.14em] text-black/40">
            one endpoint. every subscription.
          </p>
          <h1 className="max-w-4xl text-balance text-4xl font-medium leading-[1.08] tracking-[-0.045em] sm:text-6xl lg:text-7xl">
            {tagline}
          </h1>

          <div className="mt-12 inline-flex items-center gap-5 rounded-xl border border-black/10 bg-white p-2 pl-5 shadow-[0_1px_2px_rgba(0,0,0,0.04)]">
            <code className="font-mono text-sm text-black/70">
              cr codex
            </code>
            <span className="select-none rounded-lg bg-black px-4 py-2 font-mono text-xs text-white">
              private beta
            </span>
          </div>

          <p className="mt-5 max-w-xl font-mono text-[11px] leading-5 text-black/40">
            Codex and OpenCode Go are available now. Pi support is experimental.
            Claude Max and API-key routing are coming soon.
          </p>

          <div className="mt-20 grid max-w-3xl gap-px overflow-hidden rounded-xl border border-black/10 bg-black/10 sm:grid-cols-3">
            {[
              ["01", "connect", "Add subscriptions with provider-native authorization."],
              ["02", "route", "Use one OpenAI-compatible endpoint from any agent."],
              ["03", "continue", "Move to healthy capacity without changing your workflow."],
            ].map(([number, title, description]) => (
              <div key={number} className="bg-[#fafafa] p-6">
                <p className="font-mono text-[11px] text-black/30">{number}</p>
                <h2 className="mt-8 text-sm font-medium">{title}</h2>
                <p className="mt-2 text-sm leading-6 text-black/50">{description}</p>
              </div>
            ))}
          </div>
        </div>
      </section>

      <footer className="mx-auto flex h-16 max-w-6xl items-center px-6 font-mono text-[11px] text-black/30">
        coderouter.dev
      </footer>
    </main>
  );
}
