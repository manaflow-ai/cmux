import { useLocale, useTranslations } from "next-intl";
import { getTranslations } from "next-intl/server";
import { Link } from "@/i18n/navigation";
import { buildAlternates, openGraphDefaults, seoDescription, twitterSummary } from "@/i18n/seo";
import { SiteHeader } from "@/app/[locale]/components/site-header";
import { LandingCTA } from "../landing-ui";
import { LandingFaq, LandingSchema } from "../landing-schema";
import {
  fallbackContentLocales,
} from "@/i18n/locale-availability";
import {
  codingAgentPath,
  codingAgents,
} from "@/i18n/coding-agents";

export async function generateMetadata({ params }: { params: Promise<{ locale: string }> }) {
  const { locale } = await params;
  const t = await getTranslations({ locale, namespace: "landing.agents" });
  const alternates = buildAlternates(locale, "/agents");
  const title = t("metaTitle");
  const description = seoDescription(locale, t("metaDescription"));
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

const AGENTS: {
  href: string;
  key: string;
  label?: string;
  locales?: readonly string[];
}[] = [
  { href: "/agents/claude-code", key: "claude" },
  { href: "/agents/codex", key: "codex" },
  { href: "/agents/opencode", key: "opencode" },
  {
    href: "/agents/pi",
    key: "pi",
    label: "Pi",
  },
  { href: "/agents/gemini-cli", key: "geminiCli" },
  { href: "/agents/aider", key: "aider" },
  { href: "/agents/amp", key: "amp" },
  { href: "/agents/cursor-cli", key: "cursorCli" },
  ...codingAgents
    .filter((agent) => agent.genericPage || agent.slug === "oh-my-pi")
    .map((agent) => ({
      href: codingAgentPath(agent),
      key: agent.slug,
      label: agent.name,
      locales: agent.genericPage ? undefined : fallbackContentLocales,
    })),
];

export default function AgentsPage() {
  const t = useTranslations("landing.agents");
  const tl = useTranslations("landing.links");
  const locale = useLocale();
  const agents = AGENTS.filter(
    (agent) => !agent.locales || agent.locales.includes(locale),
  );
  return (
    <>
      <SiteHeader section={tl("agents")} />
      <main className="w-full max-w-3xl mx-auto px-6 py-12">
        <div className="docs-content text-[15px]">
          <LandingSchema
            namespace="landing.agents"
            path="/agents"
            agentsCrumb={false}
          />
          <h1>{t("title")}</h1>
          <p>{t("intro")}</p>

          <h2>{t("agentsTitle")}</h2>
          <p>{t("agentsBody")}</p>
          <ul>
            {agents.map((a) => (
              <li key={a.href}>
                <Link href={a.href} className="underline underline-offset-2">
                  {a.label ?? tl(a.key)}
                </Link>
              </li>
            ))}
          </ul>

          <h2>{t("organizeTitle")}</h2>
          <p>{t("organizeBody")}</p>

          <h2>{t("notifyTitle")}</h2>
          <p>{t("notifyBody")}</p>

          <h2>{t("scriptTitle")}</h2>
          <p>{t("scriptBody")}</p>

          <LandingFaq namespace="landing.agents" />

          <LandingCTA
            related={[
              { href: "/agents/claude-code", label: tl("claude") },
              { href: "/agents/codex", label: tl("codex") },
              { href: "/agents/opencode", label: tl("opencode") },
              { href: "/docs/getting-started", label: tl("getStarted") },
            ]}
          />
        </div>
      </main>
    </>
  );
}
