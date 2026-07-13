import type { Metadata } from "next";
import type { ReactNode } from "react";

import { buildAlternates } from "../../../../i18n/seo";
import {
  type PrivacyPolicySection,
  type PrivacyPolicySubsection,
  privacyPolicyForLocale,
} from "./content";

type PageProps = {
  readonly params: Promise<{ readonly locale: string }>;
};

export async function generateMetadata({ params }: PageProps): Promise<Metadata> {
  const { locale } = await params;
  const content = privacyPolicyForLocale(locale);
  return {
    title: content.metadataTitle,
    description: content.metadataDescription,
    alternates: buildAlternates(locale, "/privacy-policy"),
  };
}

export default async function PrivacyPolicyPage({ params }: PageProps) {
  const { locale } = await params;
  const content = privacyPolicyForLocale(locale);

  return (
    <>
      <h1>{content.title}</h1>
      <p>{content.lastUpdated}</p>
      {content.sections.map((section, index) => (
        <PolicySection key={index} section={section} />
      ))}
    </>
  );
}

function PolicySection({ section }: { readonly section: PrivacyPolicySection }) {
  return (
    <>
      {section.heading ? <h2>{section.heading}</h2> : null}
      <PolicyBody content={section} />
      {section.subsections?.map((subsection, index) => (
        <PolicySubsection key={index} subsection={subsection} />
      ))}
    </>
  );
}

function PolicySubsection({
  subsection,
}: {
  readonly subsection: PrivacyPolicySubsection;
}) {
  return (
    <>
      <h3>{subsection.heading}</h3>
      <PolicyBody content={subsection} />
    </>
  );
}

function PolicyBody({
  content,
}: {
  readonly content: Pick<
    PrivacyPolicySection,
    "paragraphs" | "bullets" | "afterBullets"
  >;
}) {
  return (
    <>
      {content.paragraphs?.map((paragraph, index) => (
        <p key={`paragraph-${index}`}>{linkedText(paragraph)}</p>
      ))}
      {content.bullets?.length ? (
        <ul>
          {content.bullets.map((bullet, index) => (
            <li key={index}>{linkedText(bullet)}</li>
          ))}
        </ul>
      ) : null}
      {content.afterBullets?.map((paragraph, index) => (
        <p key={`after-${index}`}>{linkedText(paragraph)}</p>
      ))}
    </>
  );
}

const markdownLinkPattern = /\[([^\]]+)]\((https?:\/\/[^)]+|mailto:[^)]+)\)/g;

function linkedText(text: string): ReactNode[] {
  const nodes: ReactNode[] = [];
  let cursor = 0;
  for (const match of text.matchAll(markdownLinkPattern)) {
    const index = match.index ?? 0;
    if (index > cursor) nodes.push(text.slice(cursor, index));
    nodes.push(
      <a key={`${index}-${match[2]}`} href={match[2]}>
        {match[1]}
      </a>,
    );
    cursor = index + match[0].length;
  }
  if (cursor < text.length) nodes.push(text.slice(cursor));
  return nodes;
}
