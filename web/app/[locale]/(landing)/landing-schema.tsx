import { useTranslations, useLocale } from "next-intl";
import {
  JsonLd,
  breadcrumbList,
  faqPage,
} from "@/app/[locale]/components/json-ld";

const stripTags = (s: string) => s.replace(/<\/?[a-zA-Z]+>/g, "");

/**
 * FAQPage + BreadcrumbList JSON-LD for an agent landing page. Reads four
 * localized Q&A pairs (faqQ1..faqQ4 / faqA1..faqA4) from the page's landing
 * namespace and the page title from `title`. Breadcrumb is Home > Agents >
 * <agent> for agent pages, or Home > <page> when `agentsCrumb` is false.
 */
export function LandingSchema({
  namespace,
  path,
  agentsCrumb = true,
}: {
  namespace: string;
  path: string;
  agentsCrumb?: boolean;
}) {
  const t = useTranslations(namespace);
  const tl = useTranslations("landing.links");
  const locale = useLocale();

  // Use raw strings (not t()) so answers containing rich <code> markup and
  // ICU-significant characters are not parsed as ICU and dropped to the key.
  // Matches the homepage FAQ schema. Tags are stripped for the plain-text value.
  const qas = [1, 2, 3, 4].map((n) => ({
    question: stripTags(t.raw(`faqQ${n}`) as string),
    answer: stripTags(t.raw(`faqA${n}`) as string),
  }));

  const crumbs = [{ name: tl("home"), path: "/" }];
  if (agentsCrumb) {
    crumbs.push({ name: tl("agents"), path: "/agents" });
  }
  crumbs.push({ name: t("title"), path });

  return (
    <>
      <JsonLd data={faqPage(qas)} />
      <JsonLd data={breadcrumbList(locale, crumbs)} />
    </>
  );
}

/** Renders the localized FAQ section body for an agent landing page. */
export function LandingFaq({ namespace }: { namespace: string }) {
  const t = useTranslations(namespace);
  const code = (chunks: React.ReactNode) => <code>{chunks}</code>;
  return (
    <section className="not-prose mt-12">
      <h2 className="text-xs font-medium text-muted tracking-tight mb-4">
        {t("faqTitle")}
      </h2>
      <div className="space-y-5 text-[15px]" style={{ lineHeight: 1.5 }}>
        {[1, 2, 3, 4].map((n) => (
          <div key={n}>
            <p className="font-medium mb-1">{t.rich(`faqQ${n}`, { code })}</p>
            <p className="text-muted">{t.rich(`faqA${n}`, { code })}</p>
          </div>
        ))}
      </div>
    </section>
  );
}
