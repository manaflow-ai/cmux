import type { Metadata } from "next";
import { getTranslations } from "next-intl/server";
import { legalMetadata, rawStringList } from "../legal-metadata";

type PageProps = {
  readonly params: Promise<{ readonly locale: string }>;
};

const definitionKeys = [
  "agreement",
  "application",
  "company",
  "content",
  "country",
  "device",
  "you",
] as const;

export async function generateMetadata({
  params,
}: PageProps): Promise<Metadata> {
  const { locale } = await params;
  const t = await getTranslations({ locale, namespace: "legal.eula" });
  return legalMetadata(
    locale,
    "/eula",
    t("metadataTitle"),
    t("metadataDescription"),
  );
}

export default async function EulaPage({ params }: PageProps) {
  const { locale } = await params;
  const t = await getTranslations({ locale, namespace: "legal.eula" });
  const restrictions = rawStringList(t, "sections.license.restrictions");

  return (
    <>
      <h1>{t("title")}</h1>
      <p>{t("lastUpdated")}</p>

      <p>{t("introduction.readCarefully")}</p>

      <h2>{t("sections.definitions.heading")}</h2>
      <p>{t("sections.definitions.intro")}</p>
      <ul>
        {definitionKeys.map((key) => (
          <li key={key}>
            <strong>{t(`sections.definitions.${key}Term`)}</strong>{" "}
            {t(`sections.definitions.${key}Text`)}
          </li>
        ))}
      </ul>

      <h2>{t("sections.acknowledgment.heading")}</h2>
      <p>{t("sections.acknowledgment.agreement")}</p>
      <p>{t("sections.acknowledgment.licensed")}</p>

      <h2>{t("sections.license.heading")}</h2>
      <h3>{t("sections.license.scopeHeading")}</h3>
      <p>{t("sections.license.scopeBody")}</p>
      <h3>{t("sections.license.restrictionsHeading")}</h3>
      <p>{t("sections.license.restrictionsIntro")}</p>
      <ul>
        {restrictions.map((restriction) => (
          <li key={restriction}>{restriction}</li>
        ))}
      </ul>

      <h2>{t("sections.intellectualProperty.heading")}</h2>
      <p>{t("sections.intellectualProperty.ownership")}</p>
      <p>{t("sections.intellectualProperty.userOwnership")}</p>

      <h2>{t("sections.modifications.heading")}</h2>
      <p>{t("sections.modifications.companyChanges")}</p>
      <p>{t("sections.modifications.updates")}</p>

      <h2>{t("sections.thirdPartyServices.heading")}</h2>
      <p>{t("sections.thirdPartyServices.body")}</p>

      <h2>{t("sections.termination.heading")}</h2>
      <p>{t("sections.termination.duration")}</p>
      <p>{t("sections.termination.breach")}</p>
      <p>{t("sections.termination.effect")}</p>

      <h2>{t("sections.warranties.heading")}</h2>
      <p>{t("sections.warranties.disclaimer")}</p>
      <p>{t("sections.warranties.jurisdiction")}</p>

      <h2>{t("sections.liability.heading")}</h2>
      <p>{t("sections.liability.limit")}</p>
      <p>{t("sections.liability.damages")}</p>

      <h2>{t("sections.indemnification.heading")}</h2>
      <p>{t("sections.indemnification.body")}</p>

      <h2>{t("sections.severability.heading")}</h2>
      <p>{t("sections.severability.body")}</p>

      <h2>{t("sections.governingLaw.heading")}</h2>
      <p>{t("sections.governingLaw.body")}</p>

      <h2>{t("sections.changes.heading")}</h2>
      <p>{t("sections.changes.body")}</p>

      <h2>{t("sections.contact.heading")}</h2>
      <p>{t("sections.contact.intro")}</p>
      <ul>
        <li>
          {t.rich("sections.contact.email", {
            email: (chunks) => (
              <a href="mailto:founders@manaflow.com">{chunks}</a>
            ),
          })}
        </li>
      </ul>
    </>
  );
}
