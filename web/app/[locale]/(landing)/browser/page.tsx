import Image from "next/image";
import { getTranslations } from "next-intl/server";
import { BrandLogoLink } from "@/app/[locale]/components/brand-logo-link";
import {
  ctaButtonBase,
  ctaButtonDefaultSize,
  ctaButtonStyle,
} from "@/app/[locale]/components/cta-styles";
import { PlatformIcon } from "@/app/[locale]/components/platform-icons";
import { SiteHeader } from "@/app/[locale]/components/site-header";
import {
  BROWSER_DISTRIBUTION_URL,
  BROWSER_NIGHTLY_AVAILABILITY,
  BROWSER_NIGHTLY_DOWNLOADS,
  BROWSER_NIGHTLY_RELEASE_URL,
  type BrowserNightlyPlatform,
} from "@/app/lib/download";
import {
  browserOpenGraphDefaults,
  browserTwitterSummary,
  buildAlternates,
  seoDescription,
} from "@/i18n/seo";

const PLATFORMS = ["macos", "windows", "linux"] as const;

export async function generateMetadata({
  params,
}: {
  params: Promise<{ locale: string }>;
}) {
  const { locale } = await params;
  const t = await getTranslations({ locale, namespace: "browserNightly" });
  const alternates = buildAlternates(locale, "/browser");
  const title = t("metaTitle");
  const description = seoDescription(locale, t("metaDescription"));

  return {
    title,
    description,
    alternates,
    openGraph: {
      ...browserOpenGraphDefaults(title),
      title,
      description,
      url: alternates.canonical,
    },
    twitter: browserTwitterSummary(title, description),
  };
}

export default async function BrowserNightlyPage() {
  const t = await getTranslations("browserNightly");

  return (
    <div className="min-h-screen">
      <SiteHeader hideLogo />

      <main className="mx-auto w-full max-w-4xl px-6 py-16 sm:py-24">
        <div className="mb-10 flex items-center gap-4" data-dev="browser-header">
          <BrandLogoLink className="shrink-0">
            <Image
              src="/logo.png"
              alt={t("logoAlt")}
              width={48}
              height={48}
              className="rounded-xl"
            />
          </BrandLogoLink>
          <div>
            <p className="mb-1 text-xs font-medium text-muted">
              {t("eyebrow")}
            </p>
            <h1 className="text-2xl font-semibold tracking-tight">
              {t("title")}
            </h1>
          </div>
        </div>

        <p className="max-w-2xl text-lg leading-relaxed text-foreground">
          {t("tagline")}
        </p>
        <p
          className="mt-3 max-w-2xl text-base text-muted"
          style={{ lineHeight: 1.5 }}
        >
          {t("subtitle")}
        </p>

        <div
          className="mt-10 grid gap-4 md:grid-cols-3"
          data-dev="browser-platforms"
        >
          {PLATFORMS.map((platform) => (
            <PlatformCard key={platform} platform={platform} />
          ))}
        </div>

        <section className="mt-12 rounded-2xl border border-border bg-code-bg/40 p-6">
          <h2 className="text-sm font-medium text-foreground">
            {t("updatesTitle")}
          </h2>
          <p
            className="mt-2 text-[15px] text-muted"
            style={{ lineHeight: 1.5 }}
          >
            {t("updatesBody")}
          </p>
          <p
            className="mt-3 text-[15px] text-muted"
            style={{ lineHeight: 1.5 }}
          >
            {t("licenseBody")}
          </p>
        </section>

        <div className="mt-8 flex flex-wrap gap-x-5 gap-y-3 text-sm">
          <a
            href={BROWSER_NIGHTLY_RELEASE_URL}
            className="text-muted underline decoration-link-underline underline-offset-2 transition-colors hover:text-foreground hover:decoration-foreground"
          >
            {t("releaseLink")}
          </a>
          <a
            href={BROWSER_DISTRIBUTION_URL}
            className="text-muted underline decoration-link-underline underline-offset-2 transition-colors hover:text-foreground hover:decoration-foreground"
          >
            {t("sourceLink")}
          </a>
        </div>
      </main>
    </div>
  );
}

async function PlatformCard({
  platform,
}: {
  platform: BrowserNightlyPlatform;
}) {
  const t = await getTranslations("browserNightly");
  const downloads = BROWSER_NIGHTLY_DOWNLOADS[platform];
  const available = BROWSER_NIGHTLY_AVAILABILITY[platform];

  return (
    <section
      className="flex min-h-64 flex-col rounded-2xl border border-border p-5"
      data-dev={`browser-${platform}`}
    >
      <div className="flex items-center gap-2.5">
        <PlatformIcon name={platform} size={20} />
        <h2 className="text-base font-medium">{t(`${platform}.name`)}</h2>
      </div>
      <p className="mt-3 text-sm text-muted" style={{ lineHeight: 1.45 }}>
        {t(`${platform}.requirements`)}
      </p>
      <p
        className={`mt-4 flex items-center gap-2 text-xs font-medium ${
          available ? "text-foreground" : "text-muted"
        }`}
      >
        <span
          className={`h-2 w-2 rounded-full ${
            available ? "bg-emerald-500" : "bg-amber-500"
          }`}
          aria-hidden="true"
        />
        {available ? t("readyStatus") : t("pendingStatus")}
      </p>

      <div className="mt-auto space-y-2 pt-6">
        {available ? (
          <>
            <a
              href={downloads.primary.url}
              className={`${ctaButtonBase} ${ctaButtonDefaultSize} w-full justify-center`}
              style={ctaButtonStyle}
            >
              {t(`${platform}.primaryCta`)}
            </a>
            <a
              href={downloads.portable.url}
              className="flex w-full items-center justify-center rounded-full border border-border px-4 py-2.5 text-sm font-medium text-foreground transition-colors hover:bg-code-bg"
            >
              {t("portableCta")}
            </a>
          </>
        ) : (
          <>
            <span
              aria-disabled="true"
              className={`${ctaButtonBase} ${ctaButtonDefaultSize} w-full cursor-not-allowed justify-center opacity-45`}
              style={ctaButtonStyle}
            >
              {t(`${platform}.primaryCta`)}
            </span>
            <span
              aria-disabled="true"
              className="flex w-full cursor-not-allowed items-center justify-center rounded-full border border-border px-4 py-2.5 text-sm font-medium text-muted opacity-60"
            >
              {t("portableCta")}
            </span>
          </>
        )}
      </div>
    </section>
  );
}
