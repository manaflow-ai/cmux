import { useTranslations } from "next-intl";
import { getTranslations } from "next-intl/server";
import { buildAlternates } from "../../../i18n/seo";
import { SiteHeader } from "../components/site-header";
import { EnterpriseContactForm } from "./enterprise-contact-form";

export async function generateMetadata({
  params,
}: {
  params: Promise<{ locale: string }>;
}) {
  const { locale } = await params;
  const t = await getTranslations({ locale, namespace: "enterprise" });
  return {
    title: t("metaTitle"),
    description: t("metaDescription"),
    alternates: buildAlternates(locale, "/enterprise"),
  };
}

export default function EnterprisePage() {
  const t = useTranslations("enterprise");
  const points = t.raw("points") as string[];

  return (
    <div className="min-h-screen">
      <SiteHeader section={t("section")} />
      <main className="mx-auto grid w-full max-w-6xl gap-10 px-6 py-16 sm:py-20 lg:grid-cols-[minmax(0,0.85fr)_minmax(0,1.15fr)]">
        <section>
          <p className="mb-3 text-sm font-medium text-muted">{t("section")}</p>
          <h1 className="max-w-xl text-3xl font-medium tracking-tight">
            {t("title")}
          </h1>
          <p className="mt-5 max-w-xl text-[15px] leading-relaxed text-muted">
            {t("body")}
          </p>
          <ul className="mt-8 grid gap-3 text-[15px] text-muted">
            {points.map((point) => (
              <li key={point} className="border-l border-border pl-4">
                {point}
              </li>
            ))}
          </ul>
        </section>

        <section
          aria-label={t("formAriaLabel")}
          className="border border-border p-5 sm:p-6"
        >
          <EnterpriseContactForm />
        </section>
      </main>
    </div>
  );
}
