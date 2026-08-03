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
import { SiteHeader } from "@/app/[locale]/components/site-header";
import {
  JsonLd,
  breadcrumbList,
  faqPage,
} from "@/app/[locale]/components/json-ld";
import { LandingCTA } from "../../landing-ui";

type Params = Promise<{ locale: string; agent: string }>;

export function generateStaticParams() {
  return genericCodingAgents.map((agent) => ({
    locale: "en",
    agent: agent.slug,
  }));
}

export async function generateMetadata({ params }: { params: Params }) {
  const { locale, agent: slug } = await params;
  const agent = findGenericCodingAgent(slug);
  if (!agent) notFound();
  const t = await getTranslations({ locale, namespace: "landing.agentDetail" });
  const name = agent.seoName ?? agent.name;
  const alternates = buildAlternates(locale, `/agents/${agent.slug}`, ["en"]);
  const title = t("metaTitle", { agent: name });
  const description = seoDescription(
    locale,
    t("metaDescription", { agent: name }),
  );
  return {
    title,
    description,
    keywords: [
      `best terminal for ${name}`,
      `${name} terminal`,
      `${name} macOS`,
      `${name} coding agent`,
    ],
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
  const t = await getTranslations({ locale, namespace: "landing.agentDetail" });
  const tl = await getTranslations({ locale, namespace: "landing.links" });
  const name = agent.seoName ?? agent.name;
  const code = (chunks: React.ReactNode) => <code>{chunks}</code>;
  const qas = [1, 2, 3, 4].map((number) => ({
    question: t(`faqQ${number}`, { agent: name }),
    answer: t(`faqA${number}`, { agent: name }),
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

          <h1>{t("title", { agent: name })}</h1>
          <p>
            {agent.command
              ? t.rich("introCommand", {
                  agent: name,
                  command: agent.command,
                  code,
                })
              : t("introGeneric", { agent: name })}
          </p>

          <h2>{t("organizeTitle", { agent: name })}</h2>
          <p>{t("organizeBody")}</p>

          <h2>{t("notifyTitle")}</h2>
          <p>{t("notifyBody")}</p>

          <h2>{t("browserTitle")}</h2>
          <p>{t("browserBody")}</p>

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
              { href: "/agents/pi", label: tl("pi") },
            ]}
          />
        </div>
      </main>
    </>
  );
}
