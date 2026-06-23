import { useTranslations } from "next-intl";
import { getTranslations } from "next-intl/server";
import { Link } from "../../../../../i18n/navigation";
import { buildAlternates } from "../../../../../i18n/seo";
import { LandingCTA } from "../../landing-ui";
import { LandingFaq, LandingSchema } from "../../landing-schema";

export async function generateMetadata({ params }: { params: Promise<{ locale: string }> }) {
  const { locale } = await params;
  const t = await getTranslations({ locale, namespace: "landing.claude" });
  return {
    title: t("metaTitle"),
    description: t("metaDescription"),
    alternates: buildAlternates(locale, "/agents/claude-code"),
  };
}

export default function ClaudeCodeTerminalPage() {
  const t = useTranslations("landing.claude");
  const tl = useTranslations("landing.links");
  const code = (chunks: React.ReactNode) => <code>{chunks}</code>;
  return (
    <>
      <LandingSchema namespace="landing.claude" path="/agents/claude-code" />
      <h1>{t("title")}</h1>
      <p>{t.rich("intro", { code })}</p>

      <h2>{t("organizeTitle")}</h2>
      <p>{t("organizeBody")}</p>

      <h2>{t("notifyTitle")}</h2>
      <p>{t("notifyBody")}</p>

      <h2>{t("teamsTitle")}</h2>
      <p>
        {t.rich("teamsBody", {
          link: (chunks) => (
            <Link href="/docs/agent-integrations/claude-code-teams" className="underline underline-offset-2">
              {chunks}
            </Link>
          ),
        })}
      </p>

      <h2>{t("iosTitle")}</h2>
      <p>{t("iosBody")}</p>

      <h2>{t("scriptTitle")}</h2>
      <p>{t("scriptBody")}</p>

      <LandingFaq namespace="landing.claude" />

      <LandingCTA
        related={[
          { href: "/agents", label: tl("agents") },
          { href: "/agents/codex", label: tl("codex") },
          { href: "/agents/opencode", label: tl("opencode") },
          { href: "/docs/agent-integrations/claude-code-teams", label: tl("claudeTeams") },
        ]}
      />
    </>
  );
}
