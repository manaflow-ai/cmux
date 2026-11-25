import { getTranslations } from "next-intl/server";
import { notFound } from "next/navigation";
import { CodeBlock } from "@/app/[locale]/components/code-block";
import { DocsHeading } from "@/app/[locale]/components/docs-heading";
import { mainThreadDocsLocales } from "@/i18n/locale-availability";
import {
  buildAlternates,
  openGraphDefaults,
  seoDescription,
  twitterSummary,
} from "@/i18n/seo";

const path = "/docs/main-thread";

const readMoreLinks = [
  {
    key: "readThreading",
    href: "https://chromium.googlesource.com/chromium/src/+/main/docs/threading_and_tasks.md",
  },
  {
    key: "readFaq",
    href: "https://chromium.googlesource.com/chromium/src/+/main/docs/threading_and_tasks_faq.md",
  },
  {
    key: "readScopedBlocking",
    href: "https://chromium.googlesource.com/chromium/src/+/main/base/threading/scoped_blocking_call.h",
  },
  {
    key: "readHangWatcher",
    href: "https://chromium.googlesource.com/chromium/src/+/main/base/threading/hang_watcher.h",
  },
  {
    key: "readRepoDoc",
    href: "https://github.com/manaflow-ai/cmux/blob/feat-cmux-next/docs/cmux-next/main-thread.md",
  },
] as const;

function assertSupportedLocale(locale: string) {
  if (!mainThreadDocsLocales.includes(locale as (typeof mainThreadDocsLocales)[number])) {
    notFound();
  }
}

export async function generateMetadata({ params }: { params: Promise<{ locale: string }> }) {
  const { locale } = await params;
  assertSupportedLocale(locale);
  const t = await getTranslations({ locale, namespace: "docs.mainThread" });
  const alternates = buildAlternates(locale, path, mainThreadDocsLocales);
  const title = t("metaTitle");
  const description = seoDescription(locale, t("metaDescription"));
  return {
    title,
    description,
    alternates,
    openGraph: {
      ...openGraphDefaults(locale, "article"),
      title,
      description,
      url: alternates.canonical,
    },
    twitter: twitterSummary(locale, title, description),
  };
}

export default async function MainThreadPage({
  params,
}: {
  params: Promise<{ locale: string }>;
}) {
  const { locale } = await params;
  assertSupportedLocale(locale);
  const t = await getTranslations({ locale, namespace: "docs.mainThread" });

  return (
    <>
      <DocsHeading level={1} id="title">{t("title")}</DocsHeading>
      <p>{t("intro")}</p>

      <DocsHeading level={2} id="top-fixes">{t("fixesTitle")}</DocsHeading>
      <ol>
        <li>{t("fixStdin")}</li>
        <li>{t("fixHibernation")}</li>
        <li>{t("fixSpawn")}</li>
        <li>{t("fixWrites")}</li>
      </ol>

      <DocsHeading level={2} id="chrome">{t("chromeTitle")}</DocsHeading>
      <ul>
        <li>{t("chromeUiThread")}</li>
        <li>{t("chromeTasks")}</li>
        <li>{t("chromeEnforced")}</li>
        <li>{t("chromeProcesses")}</li>
      </ul>

      <DocsHeading level={2} id="rule">{t("ruleTitle")}</DocsHeading>
      <p>{t("ruleIntro")}</p>
      <CodeBlock lang="swift">{`let text = try await work.run(.userVisible, mayBlock: .files) {
  try String(blockingContentsOf: url)
}
model.apply(text)`}</CodeBlock>
      <p>{t("ruleCodeNote")}</p>

      <DocsHeading level={2} id="enforced">{t("keepTitle")}</DocsHeading>
      <p>{t("keepDesc")}</p>

      <DocsHeading level={2} id="report-a-hang">{t("debugTitle")}</DocsHeading>
      <p>{t("debugDesc")}</p>
      <CodeBlock lang="bash">{`log stream --predicate 'category == "blocking"'`}</CodeBlock>

      <DocsHeading level={2} id="further-reading">{t("readMoreTitle")}</DocsHeading>
      <ul>
        {readMoreLinks.map((link) => (
          <li key={link.key}>
            <a href={link.href} target="_blank" rel="noopener noreferrer">
              {t(link.key)}
            </a>
          </li>
        ))}
      </ul>
    </>
  );
}
