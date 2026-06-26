const BASE = "https://cmux.com";

/** Build an absolute cmux.com URL for a locale + path, matching i18n/seo.ts. */
export function localizedUrl(locale: string, path: string) {
  return locale === "en" ? `${BASE}${path}` : `${BASE}/${locale}${path}`;
}

/**
 * Render a JSON-LD <script> for the given structured data. Escaping matches
 * the inline scripts in [locale]/layout.tsx and [locale]/page.tsx so it stays
 * safe inside HTML.
 */
export function JsonLd({ data }: { data: Record<string, unknown> }) {
  const json = JSON.stringify(data).replace(/</g, "\\u003c");
  return (
    <script
      type="application/ld+json"
      dangerouslySetInnerHTML={{ __html: json }}
    />
  );
}

type Crumb = { name: string; path: string };

/** Build a schema.org BreadcrumbList from ordered { name, path } items. */
export function breadcrumbList(locale: string, items: Crumb[]) {
  return {
    "@context": "https://schema.org",
    "@type": "BreadcrumbList",
    itemListElement: items.map((item, i) => ({
      "@type": "ListItem",
      position: i + 1,
      name: item.name,
      item: localizedUrl(locale, item.path),
    })),
  };
}

/** Build a schema.org FAQPage from localized question/answer pairs. */
export function faqPage(qas: { question: string; answer: string }[]) {
  return {
    "@context": "https://schema.org",
    "@type": "FAQPage",
    mainEntity: qas.map((qa) => ({
      "@type": "Question",
      name: qa.question,
      acceptedAnswer: { "@type": "Answer", text: qa.answer },
    })),
  };
}

/** Build a schema.org Article for a blog post. Author defaults to cmux. */
export function articleSchema(opts: {
  locale: string;
  path: string;
  headline: string;
  description: string;
  datePublished: string;
  authorName?: string;
}) {
  return {
    "@context": "https://schema.org",
    "@type": "Article",
    headline: opts.headline,
    description: opts.description,
    datePublished: opts.datePublished,
    author: { "@type": "Organization", name: opts.authorName ?? "cmux" },
    publisher: { "@type": "Organization", name: "cmux", url: BASE },
    mainEntityOfPage: localizedUrl(opts.locale, opts.path),
  };
}
