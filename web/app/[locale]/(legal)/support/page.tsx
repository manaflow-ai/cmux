import type { Metadata } from "next";
import { getTranslations } from "next-intl/server";
import { Link } from "../../../../i18n/navigation";

export async function generateMetadata({
  params,
}: {
  params: Promise<{ locale: string }>;
}): Promise<Metadata> {
  const { locale } = await params;
  const t = await getTranslations({ locale, namespace: "support" });

  return {
    title: t("metaTitle"),
    description: t("metaDescription"),
    alternates: { canonical: "https://cmux.com/support" },
  };
}

export default async function SupportPage() {
  const t = await getTranslations("support");

  return (
    <>
      <h1>{t("title")}</h1>
      <p>{t("intro")}</p>

      <h2>{t("emailHeading")}</h2>
      <p>
        {t("emailPrefix")}{" "}
        <a href="mailto:founders@manaflow.com">founders@manaflow.com</a>.
      </p>

      <h2>{t("issuesHeading")}</h2>
      <p>
        {t("issuesPrefix")}{" "}
        <a
          href="https://github.com/manaflow-ai/cmux/issues"
          target="_blank"
          rel="noopener noreferrer"
        >
          {t("issuesLink")}
        </a>.
      </p>

      <h2>{t("docsHeading")}</h2>
      <p>
        {t("docsPrefix")} <Link href="/docs">{t("docsLink")}</Link>.
      </p>
    </>
  );
}
