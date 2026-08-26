import type { Metadata } from "next";
import type { ReactNode } from "react";

import type { Locale } from "../../../../i18n/routing";
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
      <p>{lastUpdatedForLocale(locale)}</p>
      {content.sections.map((section, index) => (
        <PolicySection key={index} section={section} />
      ))}
    </>
  );
}

const lastUpdatedByLocale = {
  en: "Last updated: July 14, 2026",
  ja: "最終更新日: 2026 年 7 月 14 日",
  "zh-CN": "最后更新：2026 年 7 月 14 日",
  "zh-TW": "最後更新：2026 年 7 月 14 日",
  ko: "최종 업데이트: 2026년 7월 14일",
  de: "Zuletzt aktualisiert: 14. Juli 2026",
  es: "Última actualización: 14 de julio de 2026",
  fr: "Dernière mise à jour : 14 juillet 2026",
  it: "Ultimo aggiornamento: 14 luglio 2026",
  da: "Senest opdateret: 14. juli 2026",
  pl: "Ostatnia aktualizacja: 14 lipca 2026 r.",
  ru: "Последнее обновление: 14 июля 2026 г.",
  bs: "Posljednje ažuriranje: 14. juli 2026.",
  ar: "آخر تحديث: 14 يوليو 2026",
  no: "Sist oppdatert: 14. juli 2026",
  "pt-BR": "Última atualização: 14 de julho de 2026",
  th: "อัปเดตล่าสุด: 14 กรกฎาคม 2026",
  tr: "Son güncelleme: 14 Temmuz 2026",
  km: "បានធ្វើបច្ចុប្បន្នភាពចុងក្រោយ៖ 14 កក្កដា 2026",
  uk: "Останнє оновлення: 14 липня 2026 р.",
} satisfies Record<Locale, string>;

function lastUpdatedForLocale(locale: string): string {
  return lastUpdatedByLocale[locale as Locale] ?? lastUpdatedByLocale.en;
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
