import type { Metadata } from "next";
import { getTranslations } from "next-intl/server";
import { legalMetadata, rawStringList } from "../legal-metadata";

type PageProps = {
  readonly params: Promise<{ readonly locale: string }>;
};

export async function generateMetadata({
  params,
}: PageProps): Promise<Metadata> {
  const { locale } = await params;
  const t = await getTranslations({ locale, namespace: "legal.terms" });
  return legalMetadata(
    locale,
    "/terms-of-service",
    t("metadataTitle"),
    t("metadataDescription"),
  );
}

export default async function TermsOfServicePage({ params }: PageProps) {
  const { locale } = await params;
  const t = await getTranslations({ locale, namespace: "legal.terms" });
  const restrictions = rawStringList(t, "sections.license.restrictions");
  const email = (chunks: React.ReactNode) => (
    <a href="mailto:founders@manaflow.com">{chunks}</a>
  );

  return (
    <>
      <h1>{t("title")}</h1>
      <p>{t("lastRevised")}</p>

      <p>
        {t.rich("introduction.siteAndApplication", {
          site: (chunks) => <a href="https://cmux.com">{chunks}</a>,
        })}
      </p>
      <p>{t("introduction.acceptance")}</p>

      <h2>{t("sections.license.heading")}</h2>
      <p>{t("sections.license.body")}</p>

      <h3>{t("sections.license.restrictionsHeading")}</h3>
      <p>{t("sections.license.restrictionsIntro")}</p>
      <ul>
        {restrictions.map((restriction) => (
          <li key={restriction}>{restriction}</li>
        ))}
      </ul>

      <h3>{t("sections.license.modificationHeading")}</h3>
      <p>{t("sections.license.modificationBody")}</p>

      <h3>{t("sections.license.ownershipHeading")}</h3>
      <p>{t("sections.license.ownershipBody")}</p>

      <h3>{t("sections.license.feedbackHeading")}</h3>
      <p>{t("sections.license.feedbackBody")}</p>

      <h2>{t("sections.userContent.heading")}</h2>
      <p>{t("sections.userContent.body")}</p>

      <h2>{t("sections.indemnification.heading")}</h2>
      <p>{t("sections.indemnification.body")}</p>

      <h2>{t("sections.thirdPartyLinks.heading")}</h2>
      <p>{t("sections.thirdPartyLinks.body")}</p>

      <h2>{t("sections.disclaimers.heading")}</h2>
      <p>{t("sections.disclaimers.body")}</p>
      <p>{t("sections.disclaimers.jurisdiction")}</p>

      <h2>{t("sections.liability.heading")}</h2>
      <p>{t("sections.liability.damages")}</p>
      <p>{t("sections.liability.limit")}</p>

      <h2>{t("sections.termination.heading")}</h2>
      <p>{t("sections.termination.body")}</p>

      <h2>{t("sections.disputes.heading")}</h2>
      <p>{t("sections.disputes.arbitration")}</p>
      <p>{t("sections.disputes.juryWaiver")}</p>
      <p>{t("sections.disputes.classWaiver")}</p>
      <p>{t.rich("sections.disputes.optOut", { email })}</p>

      <h2>{t("sections.general.heading")}</h2>
      <p>{t("sections.general.body")}</p>

      <h2>{t("sections.contact.heading")}</h2>
      <p>{t.rich("sections.contact.body", { email })}</p>

      <p>{t("copyright", { year: new Date().getFullYear() })}</p>
    </>
  );
}
