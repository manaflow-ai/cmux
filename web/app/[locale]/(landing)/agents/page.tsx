import { useTranslations } from "next-intl";
import { getTranslations } from "next-intl/server";
import { Link } from "@/i18n/navigation";
import { buildAlternates } from "@/i18n/seo";
import { SiteHeader } from "@/app/[locale]/components/site-header";
import { LandingCTA } from "../landing-ui";
import { LandingFaq, LandingSchema } from "../landing-schema";

export async function generateMetadata({ params }: { params: Promise<{ locale: string }> }) {
  const { locale } = await params;
  const t = await getTranslations({ locale, namespace: "landing.agents" });
  return {
    title: t("metaTitle"),
    description: t("metaDescription"),
    alternates: buildAlternates(locale, "/agents"),
  };
}

const AGENTS: { href: string; key: string }[] = [
  { href: "/agents/claude-code", key: "claude" },
  { href: "/agents/codex", key: "codex" },
  { href: "/agents/opencode", key: "opencode" },
  { href: "/agents/gemini-cli", key: "geminiCli" },
  { href: "/agents/aider", key: "aider" },
  { href: "/agents/amp", key: "amp" },
  { href: "/agents/cursor-cli", key: "cursorCli" },
];

export default function AgentsPage() {
  const t = useTranslations("landing.agents");
  const tl = useTranslations("landing.links");
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
            {AGENTS.map((a) => (
              <li key={a.href}>
                <Link href={a.href} className="underline underline-offset-2">
                  {tl(a.key)}
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
