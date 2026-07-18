import { useTranslations } from "next-intl";
import { getTranslations } from "next-intl/server";
import { Link } from "../../../../i18n/navigation";
import { buildAlternates } from "../../../../i18n/seo";
import { LandingCTA } from "../landing-ui";

export async function generateMetadata({ params }: { params: Promise<{ locale: string }> }) {
  const { locale } = await params;
  const t = await getTranslations({ locale, namespace: "landing.opencode" });
  return {
    title: t("metaTitle"),
    description: t("metaDescription"),
    alternates: buildAlternates(locale, "/opencode"),
  };
}

export default function OpenCodePage() {
  const t = useTranslations("landing.opencode");
  const tl = useTranslations("landing.links");
  const code = (chunks: React.ReactNode) => <code>{chunks}</code>;
  return (
    <>
      <h1>{t("title")}</h1>
      <p>{t.rich("intro", { code })}</p>

      <h2>{t("organizeTitle")}</h2>
      <p>{t("organizeBody")}</p>

      <h2>{t("notifyTitle")}</h2>
      <p>{t("notifyBody")}</p>

      <h2>{t("omoTitle")}</h2>
      <p>
        {t.rich("omoBody", {
          code,
          link: (chunks) => (
            <Link href="/docs/agent-integrations/oh-my-opencode" className="underline underline-offset-2">
              {chunks}
            </Link>
          ),
        })}
      </p>

      <h2>{t("iosTitle")}</h2>
      <p>{t("iosBody")}</p>

      <h2>{t("scriptTitle")}</h2>
      <p>{t("scriptBody")}</p>

      <LandingCTA
        related={[
          { href: "/claude-code-terminal", label: tl("claude") },
          { href: "/codex-cli", label: tl("codex") },
          { href: "/docs/agent-integrations/oh-my-opencode", label: tl("ohMyOpenCode") },
          { href: "/docs/getting-started", label: tl("getStarted") },
        ]}
      />
    </>
  );
}
