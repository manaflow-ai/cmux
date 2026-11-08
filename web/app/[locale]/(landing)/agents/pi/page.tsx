import { getTranslations } from "next-intl/server";
import {
  buildAlternates,
  openGraphDefaults,
  seoDescription,
  twitterSummary,
} from "@/i18n/seo";
import { SiteHeader } from "@/app/[locale]/components/site-header";
import { LandingCTA } from "../../landing-ui";
import {
  JsonLd,
  breadcrumbList,
  faqPage,
} from "@/app/[locale]/components/json-ld";

export async function generateMetadata({
  params,
}: {
  params: Promise<{ locale: string }>;
}) {
  const { locale } = await params;
  const t = await getTranslations({ locale, namespace: "landing.agents" });
  const alternates = buildAlternates(locale, "/agents/pi");
  const title = `Pi: ${t("title")} | cmux`;
  const description = seoDescription(locale, `Pi. ${t("metaDescription")}`);
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

export default async function PiPage({
  params,
}: {
  params: Promise<{ locale: string }>;
}) {
  const { locale } = await params;
  const t = await getTranslations({ locale, namespace: "landing.agents" });
  const tl = await getTranslations({ locale, namespace: "landing.links" });
  const qas = [1, 2, 3, 4].map((number) => ({
    question: t(`faqQ${number}`),
    answer: t(`faqA${number}`),
  }));
  return (
    <>
      <SiteHeader section="Pi" />
      <main className="w-full max-w-3xl mx-auto px-6 py-12">
        <div className="docs-content text-[15px]">
          <JsonLd data={faqPage(qas)} />
          <JsonLd
            data={breadcrumbList(locale, [
              { name: tl("home"), path: "/" },
              { name: tl("agents"), path: "/agents" },
              { name: "Pi", path: "/agents/pi" },
            ])}
          />
          <h1>
            Pi: {t("title")}
          </h1>
          <p>{t("intro")}</p>

          <h2>{t("organizeTitle")}</h2>
          <p>{t("organizeBody")}</p>

          <h2>{t("notifyTitle")}</h2>
          <p>{t("notifyBody")}</p>

          <h2>{t("scriptTitle")}</h2>
          <p>{t("scriptBody")}</p>

          <section className="not-prose mt-12">
            <h2 className="text-xs font-medium text-muted tracking-tight mb-4">
              {t("faqTitle")}
            </h2>
            <div className="space-y-5 text-[15px]" style={{ lineHeight: 1.5 }}>
              {qas.map((qa) => (
                <div key={qa.question}>
                  <p className="font-medium mb-1">{qa.question}</p>
                  <p className="text-muted">{qa.answer}</p>
                </div>
              ))}
            </div>
          </section>

          <LandingCTA
            related={[
              { href: "/agents", label: tl("agents") },
              { href: "/agents/claude-code", label: tl("claude") },
              { href: "/agents/codex", label: tl("codex") },
              {
                href: "/docs/agent-integrations/oh-my-pi",
                label: "oh-my-pi",
              },
            ]}
          />
        </div>
      </main>
    </>
  );
}
