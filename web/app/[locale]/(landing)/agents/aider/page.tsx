import { useTranslations } from "next-intl";
import { getTranslations } from "next-intl/server";
import { buildAlternates, openGraphDefaults, seoDescription, twitterSummary } from "@/i18n/seo";
import { SiteHeader } from "@/app/[locale]/components/site-header";
import { LandingCTA } from "../../landing-ui";
import { LandingFaq, LandingSchema } from "../../landing-schema";

export async function generateMetadata({ params }: { params: Promise<{ locale: string }> }) {
  const { locale } = await params;
  const t = await getTranslations({ locale, namespace: "landing.aider" });
  const alternates = buildAlternates(locale, "/agents/aider");
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

export default function AiderPage() {
  const t = useTranslations("landing.aider");
  const tl = useTranslations("landing.links");
  const code = (chunks: React.ReactNode) => <code>{chunks}</code>;
  return (
    <>
      <SiteHeader section={tl("aider")} />
      <main className="w-full max-w-3xl mx-auto px-6 py-12">
        <div className="docs-content text-[15px]">
      <LandingSchema namespace="landing.aider" path="/agents/aider" />
      <h1>{t("title")}</h1>
      <p>{t.rich("intro", { code })}</p>

      <h2>{t("organizeTitle")}</h2>
      <p>{t("organizeBody")}</p>

      <h2>{t("notifyTitle")}</h2>
      <p>{t("notifyBody")}</p>

      <h2>{t("iosTitle")}</h2>
      <p>{t("iosBody")}</p>

      <h2>{t("scriptTitle")}</h2>
      <p>{t("scriptBody")}</p>

      <LandingFaq namespace="landing.aider" />

      <LandingCTA
        related={[
          { href: "/agents", label: tl("agents") },
          { href: "/agents/claude-code", label: tl("claude") },
          { href: "/agents/codex", label: tl("codex") },
          { href: "/docs/getting-started", label: tl("getStarted") },
        ]}
      />
        </div>
      </main>
    </>
  );
}
