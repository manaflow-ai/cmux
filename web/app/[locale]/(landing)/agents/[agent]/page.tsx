import { getTranslations } from "next-intl/server";
import { notFound } from "next/navigation";
import {
  buildAlternates,
  openGraphDefaults,
  seoDescription,
  twitterSummary,
} from "@/i18n/seo";
import {
  findGenericCodingAgent,
  genericCodingAgents,
} from "@/i18n/coding-agents";
import { locales } from "@/i18n/routing";
import { SiteHeader } from "@/app/[locale]/components/site-header";
import {
  JsonLd,
  breadcrumbList,
  faqPage,
} from "@/app/[locale]/components/json-ld";
import { LandingCTA } from "../../landing-ui";

type Params = Promise<{ locale: string; agent: string }>;

export function generateStaticParams() {
  return locales.flatMap((locale) =>
    genericCodingAgents.map((agent) => ({
      locale,
      agent: agent.slug,
    })),
  );
}

export async function generateMetadata({ params }: { params: Params }) {
  const { locale, agent: slug } = await params;
  const agent = findGenericCodingAgent(slug);
  if (!agent) notFound();
  const t = await getTranslations({ locale, namespace: "landing.agents" });
  const name = agent.seoName ?? agent.name;
  const alternates = buildAlternates(locale, `/agents/${agent.slug}`);
  const title = `${name}: ${t("title")} | cmux`;
  const description = seoDescription(
    locale,
    `${name}. ${t("metaDescription")}`,
  );
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

export default async function CodingAgentPage({ params }: { params: Params }) {
  const { locale, agent: slug } = await params;
  const agent = findGenericCodingAgent(slug);
  if (!agent) notFound();
  const t = await getTranslations({ locale, namespace: "landing.agents" });
  const tl = await getTranslations({ locale, namespace: "landing.links" });
  const name = agent.seoName ?? agent.name;
  const qas = [1, 2, 3, 4].map((number) => ({
    question: t(`faqQ${number}`),
    answer: t(`faqA${number}`),
  }));

  return (
    <>
      <SiteHeader section={agent.name} />
      <main className="w-full max-w-3xl mx-auto px-6 py-12">
        <div className="docs-content text-[15px]">
          <JsonLd data={faqPage(qas)} />
          <JsonLd
            data={breadcrumbList(locale, [
              { name: tl("home"), path: "/" },
              { name: tl("agents"), path: "/agents" },
              { name, path: `/agents/${agent.slug}` },
            ])}
          />

          <h1>
            {name}: {t("title")}
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
              { href: "/agents/pi", label: "Pi" },
            ]}
          />
        </div>
      </main>
    </>
  );
}
