import Image from "next/image";
import { getTranslations } from "next-intl/server";
import { BrandLogoLink } from "@/app/[locale]/components/brand-logo-link";
import { PlatformIcon } from "@/app/[locale]/components/platform-icons";
import { SiteHeader } from "@/app/[locale]/components/site-header";
import {
  BROWSER_MACOS_NIGHTLY_AVAILABLE,
  BROWSER_MACOS_NIGHTLY_DOWNLOAD,
  BROWSER_NIGHTLY_RELEASE_URL,
  BROWSER_RELEASE_REPOSITORY_URL,
  PLATFORM_DOWNLOAD_AVAILABILITY,
  PLATFORM_DOWNLOADS,
} from "@/app/lib/download";
import { buildAlternates, openGraphDefaults, twitterSummary } from "@/i18n/seo";
import { BrowserDownloadCardAction } from "./browser-download-card-action";

export async function generateMetadata({
  params,
}: {
  params: Promise<{ locale: string }>;
}) {
  const { locale } = await params;
  const [t, footer] = await Promise.all([
    getTranslations({ locale, namespace: "browserDownloads" }),
    getTranslations({ locale, namespace: "footer" }),
  ]);
  const alternates = buildAlternates(locale, "/browser");
  const title = `${t("eyebrow")} ${footer("nightly")}`;
  const description = t("tagline");

  return {
    title,
    description,
    alternates,
    openGraph: {
      ...openGraphDefaults(locale, "website"),
      title,
      description,
      url: alternates.canonical,
    },
    twitter: twitterSummary(locale, title, description),
  };
}

export default async function BrowserPage() {
  const [t, common, platforms, waitlist, footer] = await Promise.all([
    getTranslations("browserDownloads"),
    getTranslations("common"),
    getTranslations("platforms"),
    getTranslations("waitlist"),
    getTranslations("footer"),
  ]);
  const title = `${t("eyebrow")} ${footer("nightly")}`;
  const cards = [
    {
      platform: "macos" as const,
      name: platforms("macos"),
      cta: common("downloadForMac"),
      href: BROWSER_MACOS_NIGHTLY_DOWNLOAD.primary.url,
      artifact: BROWSER_MACOS_NIGHTLY_DOWNLOAD.primary.artifact,
      available: BROWSER_MACOS_NIGHTLY_AVAILABLE,
      requirements: null,
    },
    {
      platform: "windows" as const,
      name: t("windows.name"),
      cta: t("windows.primaryCta"),
      href: PLATFORM_DOWNLOADS.windows.primary.url,
      artifact: PLATFORM_DOWNLOADS.windows.primary.artifact,
      available: PLATFORM_DOWNLOAD_AVAILABILITY.windows,
      requirements: t("windows.requirements"),
    },
    {
      platform: "linux" as const,
      name: t("linux.name"),
      cta: t("linux.primaryCta"),
      href: PLATFORM_DOWNLOADS.linux.primary.url,
      artifact: PLATFORM_DOWNLOADS.linux.primary.artifact,
      available: PLATFORM_DOWNLOAD_AVAILABILITY.linux,
      requirements: t("linux.requirements"),
    },
  ];

  return (
    <div className="min-h-screen">
      <SiteHeader hideLogo />
      <main className="mx-auto w-full max-w-4xl px-6 py-16 sm:py-24">
        <div className="mb-10 flex items-center gap-4">
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
              {t("releaseTitle")}
            </p>
            <h1 className="text-2xl font-semibold tracking-tight">
              {title}
            </h1>
          </div>
        </div>

        <p className="max-w-2xl text-lg leading-relaxed text-foreground">
          {t("tagline")}
        </p>

        <div className="mt-10 grid gap-4 md:grid-cols-3">
          {cards.map((card) => (
            <section
              key={card.platform}
              className="flex min-h-64 flex-col rounded-2xl border border-border p-5"
              data-dev={`browser-${card.platform}`}
            >
              <div className="flex items-center gap-2.5">
                <PlatformIcon name={card.platform} size={20} />
                <h2 className="text-base font-medium">{card.name}</h2>
              </div>
              {card.requirements && (
                <p className="mt-3 text-sm text-muted">{card.requirements}</p>
              )}
              {!card.available && (
                <p className="mt-4 text-xs text-muted">
                  {waitlist("calloutText")}
                </p>
              )}
              <div className="mt-auto pt-6">
                <BrowserDownloadCardAction
                  platform={card.platform}
                  artifact={card.artifact}
                  href={card.href}
                  available={card.available}
                >
                  {card.cta}
                </BrowserDownloadCardAction>
              </div>
            </section>
          ))}
        </div>

        <section className="mt-12 rounded-2xl border border-border bg-code-bg/40 p-6">
          <h2 className="text-sm font-medium text-foreground">
            {t("releaseTitle")}
          </h2>
          <p className="mt-2 text-[15px] text-muted" style={{ lineHeight: 1.5 }}>
            {t.rich("releaseBody", {
              github: (chunks) => (
                <a
                  href={BROWSER_NIGHTLY_RELEASE_URL}
                  className="underline decoration-link-underline underline-offset-2 transition-colors hover:decoration-foreground"
                >
                  {chunks}
                </a>
              ),
            })}
          </p>
        </section>

        <div className="mt-8 text-sm">
          <a
            href={BROWSER_RELEASE_REPOSITORY_URL}
            className="text-muted underline decoration-link-underline underline-offset-2 transition-colors hover:text-foreground hover:decoration-foreground"
          >
            {t("sourceLink")}
          </a>
        </div>
      </main>
    </div>
  );
}
