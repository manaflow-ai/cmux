import { getTranslations, setRequestLocale } from "next-intl/server";
import { Suspense } from "react";
import { buildAlternates } from "../../../i18n/seo";
import { SiteHeader } from "../components/site-header";
import { ProCheckoutButton } from "../components/pro-checkout-button";
import { ProWelcomeBanner } from "../components/pro-welcome-banner";

export async function generateMetadata({
  params,
}: {
  params: Promise<{ locale: string }>;
}) {
  const { locale } = await params;
  const t = await getTranslations({ locale, namespace: "pro" });
  return {
    title: t("metaTitle"),
    description: t("metaDescription"),
    alternates: buildAlternates(locale, "/pro"),
  };
}

const VALUE_KEYS = [
  "cloudVms",
  "vmCreates",
  "ios",
  "ai",
  "support",
] as const;

export default async function ProPage({
  params,
}: {
  params: Promise<{ locale: string }>;
}) {
  const { locale } = await params;
  setRequestLocale(locale);

  const t = await getTranslations("pro");

  return (
    <div className="min-h-screen">
      <SiteHeader section={t("section")} />
      <main className="w-full max-w-2xl mx-auto px-6 py-16 sm:py-24">
        <Suspense fallback={null}>
          <ProWelcomeBanner />
        </Suspense>

        <h1 className="text-2xl font-semibold tracking-tight mb-3">
          {t("title")}
        </h1>
        <p className="text-base text-muted mb-10" style={{ lineHeight: 1.5 }}>
          {t("tagline")}
        </p>

        <ul className="space-y-3 text-[15px] mb-10" style={{ lineHeight: 1.4 }}>
          {VALUE_KEYS.map((key) => (
            <li key={key} className="flex gap-3">
              <span className="text-muted shrink-0">-</span>
              <span>
                <strong className="font-medium">{t(`value.${key}`)}</strong>{" "}
                <span className="text-muted">{t(`value.${key}Desc`)}</span>
              </span>
            </li>
          ))}
        </ul>

        <div className="mb-8">
          <p className="text-2xl font-semibold tracking-tight">
            {t("priceHeadline")}
          </p>
          <p className="text-[15px] text-muted mt-1">{t("priceDetail")}</p>
        </div>

        <div className="flex flex-wrap items-center gap-4">
          <ProCheckoutButton location="pro_page" />
          <span className="text-sm text-muted">{t("cancelNote")}</span>
        </div>
      </main>
    </div>
  );
}
