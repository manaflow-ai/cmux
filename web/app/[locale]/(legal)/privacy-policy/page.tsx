import type { Metadata } from "next";
import type { ReactNode } from "react";
import { getTranslations } from "next-intl/server";
import { buildAlternates } from "../../../../i18n/seo";
import { Link } from "../../../../i18n/navigation";

const privacyPolicyLocales = ["en"] as const;

type PrivacyPolicyBlock =
  | { type: "p"; text: string }
  | { type: "h2"; text: string }
  | { type: "h3"; text: string }
  | { type: "ul"; items: string[] };

type PageParams = { locale: string };

export async function generateMetadata({
  params,
}: {
  params: Promise<PageParams>;
}): Promise<Metadata> {
  await params;
  const t = await getTranslations({ locale: "en", namespace: "privacyPolicyPage" });

  return {
    title: t("metaTitle"),
    description: t("metaDescription"),
    alternates: buildAlternates("en", "/privacy-policy", privacyPolicyLocales),
  };
}

export default async function PrivacyPolicyPage({
  params,
}: {
  params: Promise<PageParams>;
}) {
  await params;
  const t = await getTranslations({ locale: "en", namespace: "privacyPolicyPage" });
  const blocks = t.raw("blocks") as PrivacyPolicyBlock[];

  return (
    <>
      <h1>{t("title")}</h1>
      <p>{t("lastUpdated")}</p>
      {blocks.map(renderBlock)}
    </>
  );
}

function renderBlock(block: PrivacyPolicyBlock, index: number): ReactNode {
  const key = `${block.type}-${index}`;

  switch (block.type) {
    case "h2":
      return <h2 key={key}>{block.text}</h2>;
    case "h3":
      return <h3 key={key}>{block.text}</h3>;
    case "ul":
      return (
        <ul key={key}>
          {block.items.map((item) => (
            <li key={item}>{renderInline(item)}</li>
          ))}
        </ul>
      );
    case "p":
      return <p key={key}>{renderInline(block.text)}</p>;
  }
}

function renderInline(message: string): ReactNode[] {
  const nodes: ReactNode[] = [];
  const tagPattern = /<([A-Za-z][A-Za-z0-9]*)>(.*?)<\/\1>/g;
  let lastIndex = 0;
  let key = 0;

  for (const match of message.matchAll(tagPattern)) {
    const [fullMatch, tagName, chunks] = match;
    const index = match.index ?? 0;
    if (index > lastIndex) {
      nodes.push(message.slice(lastIndex, index));
    }

    nodes.push(renderInlineTag(tagName, chunks, key));
    key += 1;
    lastIndex = index + fullMatch.length;
  }

  if (lastIndex < message.length) {
    nodes.push(message.slice(lastIndex));
  }

  return nodes;
}

function renderInlineTag(tagName: string, chunks: string, key: number): ReactNode {
  switch (tagName) {
    case "site":
      return (
        <a key={key} href="https://cmux.com">
          {chunks}
        </a>
      );
    case "terms":
      return (
        <Link key={key} href="/terms-of-service">
          {chunks}
        </Link>
      );
    case "email":
      return (
        <a key={key} href="mailto:founders@manaflow.com">
          {chunks}
        </a>
      );
    default:
      return chunks;
  }
}
