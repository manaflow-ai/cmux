import { useTranslations } from "next-intl";
import { getTranslations } from "next-intl/server";
import { buildAlternates, openGraphDefaults, seoDescription, twitterSummary } from "@/i18n/seo";
import { SiteHeader } from "@/app/[locale]/components/site-header";
import { LandingCTA } from "../landing-ui";

export async function generateMetadata({ params }: { params: Promise<{ locale: string }> }) {
  const { locale } = await params;
  const t = await getTranslations({ locale, namespace: "landing.ghostty" });
  const alternates = buildAlternates(locale, "/built-on-ghostty");
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

export default function BuiltOnGhosttyPage() {
  const t = useTranslations("landing.ghostty");
  const tl = useTranslations("landing.links");
  return (
    <>
      <SiteHeader section={tl("builtOnGhostty")} />
      <main className="w-full max-w-3xl mx-auto px-6 py-12">
        <div className="docs-content text-[15px]">
          <h1>{t("title")}</h1>
          <p>
            {t.rich("intro", {
              link: (chunks) => (
                <a href="https://github.com/ghostty-org/ghostty" className="underline underline-offset-2">
                  {chunks}
                </a>
              ),
            })}
          </p>

          <h2>{t("addsTitle")}</h2>
          <p>{t("addsIntro")}</p>
          <ul>
            <li>{t("add1")}</li>
            <li>{t("add2")}</li>
            <li>{t("add3")}</li>
            <li>{t("add4")}</li>
          </ul>

          <h2>{t("whyTitle")}</h2>
          <p>{t.rich("whyBody", { code: (chunks) => <code>{chunks}</code> })}</p>

          <LandingCTA
            related={[
              { href: "/best-terminal-for-mac", label: tl("bestTerminal") },
              { href: "/docs/configuration", label: tl("configuration") },
              { href: "/docs/getting-started", label: tl("getStarted") },
            ]}
          />
        </div>
      </main>
    </>
  );
}
