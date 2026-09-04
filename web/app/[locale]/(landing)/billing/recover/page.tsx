import type { Metadata } from "next";
import { getTranslations } from "next-intl/server";
import { SiteHeader } from "../../../components/site-header";
import { Link } from "../../../../../i18n/navigation";
import { RecoverBillingForm } from "./recover-billing-form";
import {
  buildAlternates,
  openGraphDefaults,
  twitterSummary,
} from "../../../../../i18n/seo";

export async function generateMetadata({
  params,
}: {
  params: Promise<{ locale: string }>;
}): Promise<Metadata> {
  const { locale } = await params;
  const t = await getTranslations({ locale, namespace: "billingRecovery" });
  const alternates = buildAlternates(locale, "/billing/recover");
  const title = t("metaTitle");
  const description = t("metaDescription");
  return {
    title,
    description,
    alternates,
    openGraph: { ...openGraphDefaults(locale, "website"), title, description },
    twitter: twitterSummary(locale, title, description),
  };
}

export default async function BillingRecoveryPage() {
  const t = await getTranslations("billingRecovery");

  return (
    <div className="min-h-screen">
      <SiteHeader section={t("eyebrow")} />
      <main className="mx-auto grid w-full max-w-6xl gap-10 px-6 py-16 sm:py-20 lg:grid-cols-[minmax(0,0.9fr)_minmax(0,1.1fr)]">
        <section>
          <p className="mb-3 text-sm font-medium text-muted">{t("eyebrow")}</p>
          <h1 className="max-w-xl text-3xl font-medium tracking-tight">
            {t("title")}
          </h1>
          <p className="mt-5 max-w-xl text-[15px] leading-relaxed text-muted">
            {t("body")}
          </p>
          <p className="mt-8 max-w-xl border-l border-border pl-4 text-[15px] leading-relaxed text-muted">
            {t("differentEmail")}
          </p>
        </section>

        <section
          aria-label={t("formAriaLabel")}
          className="border border-border p-5 sm:p-6"
        >
          <RecoverBillingForm />
          <Link
            href="/"
            className="mt-5 inline-block text-sm text-muted underline underline-offset-2 decoration-link-underline hover:text-foreground"
          >
            {t("backToHome")}
          </Link>
        </section>
      </main>
    </div>
  );
}
