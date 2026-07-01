import { getTranslations, setRequestLocale } from "next-intl/server";
import { Suspense } from "react";
import { buildAlternates } from "../../../i18n/seo";
import { SiteHeader } from "../components/site-header";
import { DownloadButton } from "../components/download-button";
import { ProCheckoutButton } from "../components/pro-checkout-button";
import { ProWelcomeBanner } from "../components/pro-welcome-banner";

export async function generateMetadata({
  params,
}: {
  params: Promise<{ locale: string }>;
}) {
  const { locale } = await params;
  const t = await getTranslations({ locale, namespace: "pricing" });
  return {
    title: t("metaTitle"),
    description: t("metaDescription"),
    alternates: buildAlternates(locale, "/pricing"),
  };
}

const FREE_FEATURES = ["f1", "f2", "f3", "f4"] as const;
const PRO_FEATURES = ["p1", "p2", "p3", "p4", "p5"] as const;

export default async function PricingPage({
  params,
}: {
  params: Promise<{ locale: string }>;
}) {
  const { locale } = await params;
  setRequestLocale(locale);

  const t = await getTranslations("pricing");

  return (
    <div className="min-h-screen">
      <SiteHeader section={t("section")} />
      <main className="w-full max-w-3xl mx-auto px-6 py-16 sm:py-24">
        <Suspense fallback={null}>
          <ProWelcomeBanner />
        </Suspense>

        <h1 className="text-2xl font-semibold tracking-tight mb-3">
          {t("title")}
        </h1>
        <p className="text-base text-muted mb-10" style={{ lineHeight: 1.5 }}>
          {t("subtitle")}
        </p>

        <div className="grid gap-6 sm:grid-cols-2">
          {/* Free */}
          <section className="rounded-xl border border-border p-6 flex flex-col">
            <h2 className="text-sm font-semibold tracking-tight">
              {t("free.name")}
            </h2>
            <p className="mt-3">
              <span className="text-2xl font-semibold tracking-tight">
                {t("free.price")}
              </span>
            </p>
            <p className="text-sm text-muted mt-1 mb-5">{t("free.tagline")}</p>
            <ul
              className="space-y-2.5 text-sm mb-6 flex-1"
              style={{ lineHeight: 1.4 }}
            >
              {FREE_FEATURES.map((key) => (
                <li key={key} className="flex gap-2.5">
                  <span className="text-muted shrink-0">-</span>
                  <span className="text-muted">{t(`free.${key}`)}</span>
                </li>
              ))}
            </ul>
            <div>
              <DownloadButton size="sm" location="pricing_free" />
            </div>
          </section>

          {/* Pro */}
          <section className="rounded-xl border border-foreground/25 p-6 flex flex-col">
            <h2 className="text-sm font-semibold tracking-tight">
              {t("pro.name")}
            </h2>
            <p className="mt-3">
              <span className="text-2xl font-semibold tracking-tight">
                {t("pro.price")}
              </span>
              <span className="text-sm text-muted">{t("pro.priceUnit")}</span>
            </p>
            <p className="text-sm text-muted mt-1 mb-5">{t("pro.priceNote")}</p>
            <ul
              className="space-y-2.5 text-sm mb-6 flex-1"
              style={{ lineHeight: 1.4 }}
            >
              {PRO_FEATURES.map((key) => (
                <li key={key} className="flex gap-2.5">
                  <span className="text-muted shrink-0">-</span>
                  <span className="text-muted">{t(`pro.${key}`)}</span>
                </li>
              ))}
            </ul>
            <div>
              <ProCheckoutButton size="sm" location="pricing_pro" />
            </div>
          </section>
        </div>

        <p className="text-sm text-muted mt-6">{t("cancelNote")}</p>
      </main>
    </div>
  );
}
