import { Link } from "@/i18n/navigation";
import { notFound } from "next/navigation";
import { SiteHeader } from "@/app/[locale]/components/site-header";
import { CodeBlock } from "@/app/[locale]/components/code-block";
import { LandingCTA } from "../landing-ui";
import { buildAlternates, openGraphDefaults, twitterSummary } from "@/i18n/seo";

export async function generateMetadata({
  params,
}: {
  params: Promise<{ locale: string }>;
}) {
  const { locale } = await params;
  if (locale !== "en") {
    notFound();
  }
  const alternates = buildAlternates(locale, "/cua");
  const title = "Computer use for coding agents | cmux";
  const description =
    "Give coding agents a real browser and terminal they can see, click, type into, and verify from one scriptable macOS workspace.";

  return {
    title,
    description,
    alternates,
    openGraph: {
      ...openGraphDefaults(locale, "website"),
      title,
      description,
      url: alternates.canonical,
    },
    twitter: twitterSummary(locale, title, description),
  };
}

function WindowChrome({ children }: { children: React.ReactNode }) {
  return (
    <div className="overflow-hidden rounded-2xl border border-border bg-code-bg shadow-2xl shadow-black/10">
      <div className="flex items-center gap-1.5 border-b border-border px-4 py-3">
        <span className="h-2.5 w-2.5 rounded-full bg-[#ff5f57]" />
        <span className="h-2.5 w-2.5 rounded-full bg-[#febc2e]" />
        <span className="h-2.5 w-2.5 rounded-full bg-[#28c840]" />
        <span className="ml-3 font-mono text-[11px] text-muted">cmux / computer use</span>
      </div>
      {children}
    </div>
  );
}

export default async function ComputerUsePage({
  params,
}: {
  params: Promise<{ locale: string }>;
}) {
  const { locale } = await params;
  if (locale !== "en") {
    notFound();
  }

  return (
    <>
      <SiteHeader section="Computer use" />
      <main>
        <section className="mx-auto grid w-full max-w-6xl gap-12 px-6 pb-20 pt-16 sm:pt-24 lg:grid-cols-[0.9fr_1.1fr] lg:items-center lg:gap-16">
          <div>
            <p className="mb-5 font-mono text-xs uppercase tracking-[0.18em] text-muted">
              cmux / computer use
            </p>
            <h1 className="max-w-xl text-4xl font-semibold tracking-[-0.04em] text-foreground sm:text-6xl sm:leading-[1.02]">
              Give your agent a computer it can actually use.
            </h1>
            <p className="mt-6 max-w-xl text-lg leading-relaxed text-muted sm:text-xl">
              A real browser and terminal surface, inside the workspace where your agent already runs. Navigate, click, type, inspect, and verify without hiding the work behind a remote desktop.
            </p>
            <div className="mt-8 flex flex-wrap items-center gap-3">
              <Link
                href="/docs/browser-automation"
                className="inline-flex h-10 items-center rounded-full bg-foreground px-5 text-sm font-medium text-background transition-opacity hover:opacity-80"
              >
                Read the browser API
              </Link>
              <a
                href="https://github.com/manaflow-ai/cmux"
                className="inline-flex h-10 items-center rounded-full border border-border px-5 text-sm font-medium transition-colors hover:bg-muted/10"
              >
                View on GitHub
              </a>
            </div>
            <p className="mt-5 text-xs text-muted">
              Open source. Local-first. Built into cmux for macOS.
            </p>
          </div>

          <WindowChrome>
            <div className="grid min-h-[360px] grid-cols-[42%_58%] font-mono text-[11px] leading-relaxed">
              <div className="border-r border-border bg-background/60 p-4">
                <div className="mb-5 text-muted">agent / checkout-flow</div>
                <div className="space-y-3 text-muted">
                  <p><span className="text-[#28c840]">✓</span> open browser surface</p>
                  <p><span className="text-[#28c840]">✓</span> navigate to checkout</p>
                  <p><span className="text-[#28c840]">✓</span> fill billing form</p>
                  <p><span className="text-[#febc2e]">→</span> waiting for review</p>
                </div>
                <div className="mt-10 rounded-lg border border-border bg-code-bg p-3 text-muted">
                  <div className="text-foreground">notification</div>
                  <div className="mt-1">Checkout ready for approval</div>
                </div>
              </div>
              <div className="bg-[#f7f7f5] p-4 text-[#202124] dark:bg-[#202124] dark:text-[#f7f7f5]">
                <div className="mb-4 flex items-center gap-2 rounded-md border border-black/10 bg-white/70 px-3 py-2 text-[10px] text-black/50 dark:border-white/10 dark:bg-black/20 dark:text-white/50">
                  <span className="text-[#28c840]">●</span> app.example.com/checkout
                </div>
                <div className="mx-auto mt-8 max-w-[260px] rounded-lg border border-black/10 bg-white p-5 shadow-sm dark:border-white/10 dark:bg-[#2b2b2b]">
                  <div className="h-2 w-16 rounded bg-black/15 dark:bg-white/15" />
                  <div className="mt-5 space-y-3">
                    <div className="h-8 rounded border border-black/15 dark:border-white/15" />
                    <div className="h-8 rounded border border-black/15 dark:border-white/15" />
                    <div className="h-8 rounded bg-[#ff6b35]" />
                  </div>
                  <div className="mt-3 text-center text-[9px] opacity-50">snapshot captured · 12:42:08</div>
                </div>
              </div>
            </div>
          </WindowChrome>
        </section>

        <section className="border-y border-border bg-muted/5">
          <div className="mx-auto grid w-full max-w-6xl gap-px px-6 py-px sm:grid-cols-3">
            {[
              ["See", "Screenshots and DOM snapshots give the agent grounded context before it acts."],
              ["Act", "Click, type, fill, scroll, and run JavaScript through a stable CLI or socket API."],
              ["Prove", "Capture the final state, inspect errors, and leave a reviewable trail in the same workspace."],
            ].map(([title, body]) => (
              <div key={title} className="bg-background py-8 sm:px-6 sm:py-10">
                <p className="font-mono text-xs uppercase tracking-[0.16em] text-muted">{title}</p>
                <p className="mt-3 max-w-xs text-[15px] leading-relaxed text-foreground">{body}</p>
              </div>
            ))}
          </div>
        </section>

        <section className="mx-auto grid w-full max-w-6xl gap-12 px-6 py-20 sm:py-28 lg:grid-cols-2 lg:gap-20">
          <div>
            <p className="font-mono text-xs uppercase tracking-[0.16em] text-muted">One surface, two controls</p>
            <h2 className="mt-4 max-w-lg text-3xl font-semibold tracking-[-0.03em] sm:text-4xl">The agent can drive the browser. You can see every move.</h2>
            <p className="mt-5 max-w-lg text-[16px] leading-relaxed text-muted">Computer use should be inspectable. cmux keeps the browser beside the agent’s terminal, so a person can take over at any point and an agent can leave behind evidence instead of a vague “done.”</p>
            <div className="mt-8 space-y-4 text-sm">
              {[
                "Browser surfaces live beside terminal panes and persist with the workspace.",
                "Snapshots expose interactive elements without relying on fragile coordinates.",
                "The same commands work from a shell, a skill, or the Unix socket API.",
              ].map((item) => (
                <div key={item} className="flex gap-3"><span className="mt-0.5 text-[#ff6b35]">✦</span><span>{item}</span></div>
              ))}
            </div>
          </div>
          <div>
            <CodeBlock title="agent.sh" lang="bash">{`surface=$(cmux browser open https://example.com/checkout)\ncmux browser "$surface" wait --load-state complete\ncmux browser "$surface" snapshot --interactive --compact\ncmux browser "$surface" fill '#email' --text 'dev@example.com'\ncmux browser "$surface" click 'button[type=submit]' --snapshot-after\ncmux browser "$surface" screenshot /tmp/checkout.png`}</CodeBlock>
            <p className="mt-3 text-xs leading-relaxed text-muted">Every action returns structured output. Pipe it into the next step, save it as evidence, or hand the surface to a human.</p>
          </div>
        </section>

        <section className="mx-auto w-full max-w-6xl px-6 pb-20 sm:pb-28">
          <div className="rounded-2xl border border-border bg-code-bg/40 p-7 sm:p-10">
            <div className="grid gap-8 lg:grid-cols-[1fr_1.2fr] lg:items-center">
              <div>
                <p className="font-mono text-xs uppercase tracking-[0.16em] text-muted">Made for agent workflows</p>
                <h2 className="mt-3 text-2xl font-semibold tracking-[-0.03em] sm:text-3xl">Computer use is a capability, not a separate app.</h2>
              </div>
              <p className="max-w-xl text-[15px] leading-relaxed text-muted">Use it for web QA, authenticated dashboards, release checklists, research, and any task where a terminal-only agent needs to look at the thing it just changed. Keep credentials, context, and review in the workspace you already trust.</p>
            </div>
          </div>
        </section>

        <section className="mx-auto w-full max-w-3xl px-6 pb-24 text-center sm:pb-32">
          <h2 className="text-3xl font-semibold tracking-[-0.03em] sm:text-4xl">Give your next agent run eyes and hands.</h2>
          <p className="mx-auto mt-4 max-w-xl text-[16px] leading-relaxed text-muted">cmux is free, open source, and built for the tools you already use.</p>
          <LandingCTA related={[{ href: "/docs/browser-automation", label: "Browser automation docs" }, { href: "/docs/api", label: "CLI and socket API" }, { href: "/agents", label: "Coding agents" }]} />
        </section>
      </main>
    </>
  );
}
