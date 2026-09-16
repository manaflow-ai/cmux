import Image from "next/image";
import { Link } from "@/i18n/navigation";
import { notFound } from "next/navigation";
import { SiteHeader } from "@/app/[locale]/components/site-header";
import { CodeBlock } from "@/app/[locale]/components/code-block";
import { BrandLogoLink } from "@/app/[locale]/components/brand-logo-link";
import { GitHubButton } from "@/app/[locale]/components/github-button";
import {
  ctaButtonBase,
  ctaButtonDefaultSize,
  ctaButtonStyle,
} from "@/app/[locale]/components/cta-styles";
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
      <SiteHeader hideLogo />
      <main className="w-full max-w-2xl mx-auto px-6 py-16 sm:py-24">
        <div className="mb-10 flex items-center gap-4" data-dev="cua-header">
          <BrandLogoLink className="shrink-0">
            <Image
              src="/logo.png"
              alt="cmux icon"
              width={48}
              height={48}
              className="rounded-xl"
            />
          </BrandLogoLink>
          <div>
            <h1 className="text-2xl font-semibold tracking-tight">Computer use</h1>
          </div>
        </div>

        <p className="text-lg leading-relaxed mb-3 text-foreground">
          Give your agent a computer it can actually use.
        </p>
        <p className="text-base text-muted" style={{ lineHeight: 1.5 }}>
          cmux Computer Use lets agents see and operate the apps on your Mac, with the same permissions and controls you use yourself. Keep the agent, the browser, and your review in one workspace.
        </p>

        <div
          className="flex flex-wrap items-center gap-3"
          data-dev="cua-cta"
          style={{ marginTop: 21, marginBottom: 16 }}
        >
          <Link
            href="/docs/browser-automation"
            className={`${ctaButtonBase} ${ctaButtonDefaultSize}`}
            style={ctaButtonStyle}
          >
            Read the browser API
          </Link>
          <GitHubButton location="landing" />
        </div>

        <figure className="my-12">
          <div className="overflow-hidden rounded-xl border border-border bg-code-bg shadow-[0_18px_50px_rgba(0,0,0,0.14)]">
            <Image
              src="/cua-permissions.png"
              alt="cmux Computer Use permission setup showing Accessibility and Screenshots access"
              width={1200}
              height={880}
              priority
              sizes="(max-width: 640px) 100vw, 672px"
              className="h-auto w-full"
            />
          </div>
          <figcaption className="mt-3 text-center text-xs text-muted">
            Computer Use permissions are managed by a separate helper, so your terminal sessions stay open.
          </figcaption>
        </figure>

        <div className="docs-content mt-14 text-[15px]">
          <h2>See, act, and prove</h2>
          <p>
            Computer use is a capability inside cmux, not a second app. Claude Code and Codex receive the bundled <code>cmux-cua</code> MCP server automatically, so an agent can inspect a real app, take an action, and capture the result while you watch the same surface beside its terminal.
          </p>
          <ul>
            <li><strong>See:</strong> use screenshots and accessibility trees for grounded context.</li>
            <li><strong>Act:</strong> click, type, scroll, drag, and press keys in real macOS apps.</li>
            <li><strong>Prove:</strong> capture the final state, inspect errors, and leave a reviewable trail.</li>
          </ul>

          <h2>Computer Use tools</h2>
          <p>
            There is no separate user-facing <code>cmux cua</code> shell command. The <code>cmux-cua</code> binary is the bundled MCP broker that exposes these tools to the agent session:
          </p>
          <CodeBlock title="cmux-cua / MCP" lang="text">{`get_app_state(app="Safari")\n# returns a screenshot and accessibility tree\nclick(element_index="42")\ntype_text(element_index="17", text="hello")\nscroll(direction="down")\nget_app_state(app="Safari")`}</CodeBlock>

          <h2>Browser surfaces</h2>
          <p>
            For web pages, browser surfaces persist with the workspace and stay visible to a person. Agents can drive them with the cmux CLI and stable selectors, while humans can take over at any point.
          </p>
          <CodeBlock title="agent.sh" lang="bash">{`surface=$(cmux browser open https://example.com/checkout)\ncmux browser "$surface" wait --load-state complete\ncmux browser "$surface" snapshot --interactive --compact\ncmux browser "$surface" fill '#email' --text 'dev@example.com'\ncmux browser "$surface" click 'button[type=submit]' --snapshot-after\ncmux browser "$surface" screenshot /tmp/checkout.png`}</CodeBlock>

          <h2>Built for agent workflows</h2>
          <p>
            Use it for web QA, authenticated dashboards, release checklists, research, and any task where a terminal-only agent needs to look at the thing it just changed. The same commands work from a shell, a skill, or the Unix socket API.
          </p>

          <LandingCTA
            related={[
              { href: "/docs/browser-automation", label: "Browser automation docs" },
              { href: "/docs/api", label: "CLI and socket API" },
              { href: "/agents", label: "Coding agents" },
            ]}
          />
        </div>
      </main>
    </>
  );
}
