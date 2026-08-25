import Image from "next/image";
import { getTranslations } from "next-intl/server";
import { BrandLogoLink } from "@/app/[locale]/components/brand-logo-link";
import {
  ctaButtonBase,
  ctaButtonDefaultSize,
  ctaButtonStyle,
} from "@/app/[locale]/components/cta-styles";
import { PlatformDownloadLink } from "@/app/[locale]/components/platform-download-link";
import { PlatformIcon } from "@/app/[locale]/components/platform-icons";
import { SiteHeader } from "@/app/[locale]/components/site-header";
import {
  BROWSER_NIGHTLY_RELEASE_URL,
  BROWSER_RELEASE_REPOSITORY_URL,
  isPlatformDownloadAvailable,
  PLATFORM_DOWNLOADS,
  type DownloadPlatform,
} from "@/app/lib/download";
import { Link } from "@/i18n/navigation";

/** Renders the localized download, install, and release details for a platform. */
export async function PlatformDownloadPage({
  platform,
}: {
  platform: DownloadPlatform;
}) {
  const t = await getTranslations("browserDownloads");
  const downloads = PLATFORM_DOWNLOADS[platform];
  const isWindows = platform === "windows";
  const otherPlatform = isWindows ? "linux" : "windows";
  const platformName = t(`${platform}.name`);
  const featureKeys = [
    "chromium",
    "workspaces",
    "terminals",
    "openSource",
  ] as const;

  return (
    <div className="min-h-screen">
      <SiteHeader hideLogo />

      <main className="mx-auto w-full max-w-2xl px-6 py-16 sm:py-24">
        <div
          className="mb-10 flex items-center gap-4"
          data-dev={`${platform}-header`}
        >
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
            <h1 className="flex items-center gap-2.5 text-2xl font-semibold tracking-tight">
              <PlatformIcon name={platform} size={22} />
              {t("title", { platform: platformName })}
            </h1>
          </div>
        </div>

        <p className="mb-3 text-lg leading-relaxed text-foreground">
          {t("tagline")}
        </p>
        <p className="text-base text-muted" style={{ lineHeight: 1.5 }}>
          {t(`${platform}.subtitle`)}
        </p>

        <div
          className="mt-[21px] mb-4 flex flex-wrap items-center gap-3"
          data-dev={`${platform}-downloads`}
        >
          <PlatformDownloadLink
            href={downloads.primary.url}
            platform={platform}
            artifact={downloads.primary.artifact}
            location="hero"
            className={`${ctaButtonBase} ${ctaButtonDefaultSize} w-full max-w-full justify-center sm:w-auto`}
            style={ctaButtonStyle}
          >
            <DownloadIcon />
            <span className="min-w-0 text-balance whitespace-normal text-center">
              {t(`${platform}.primaryCta`)}
            </span>
          </PlatformDownloadLink>
          <PlatformDownloadLink
            href={downloads.secondary.url}
            platform={platform}
            artifact={downloads.secondary.artifact}
            location="hero-secondary"
            className="inline-flex items-center gap-2 rounded-full border border-border px-4 py-2.5 text-[15px] font-medium text-foreground transition-colors hover:bg-code-bg"
          >
            {t(`${platform}.secondaryCta`)}
          </PlatformDownloadLink>
        </div>
        <p className="text-xs text-muted">
          {t(`${platform}.requirements`)}
        </p>

        <section className="mt-12" data-dev={`${platform}-features`}>
          <h2 className="mb-3 text-xs font-medium tracking-tight text-muted">
            {t("featuresTitle")}
          </h2>
          <ul className="space-y-3 text-[15px]" style={{ lineHeight: 1.35 }}>
            {featureKeys.map((key) => (
              <li key={key} className="flex gap-3">
                <span className="shrink-0 text-muted">-</span>
                <span>
                  <strong className="font-medium">
                    {t(`features.${key}.title`)}
                  </strong>
                  <span className="text-muted">
                    {t(`features.${key}.description`)}
                  </span>
                </span>
              </li>
            ))}
          </ul>
        </section>

        <section className="mt-10" data-dev={`${platform}-install`}>
          <h2 className="mb-3 text-xs font-medium tracking-tight text-muted">
            {t("installTitle")}
          </h2>
          <p className="text-[15px] text-muted" style={{ lineHeight: 1.5 }}>
            {t(`${platform}.installBody`)}
          </p>
          {!isWindows && (
            <pre className="mt-4 overflow-x-auto rounded-xl border border-border bg-code-bg px-4 py-3 text-sm text-foreground">
              <code>
                {"chmod +x cmux-linux-x64-installer.run\n" +
                  "./cmux-linux-x64-installer.run"}
              </code>
            </pre>
          )}
        </section>

        <section className="mt-10" data-dev={`${platform}-release`}>
          <h2 className="mb-3 text-xs font-medium tracking-tight text-muted">
            {t("releaseTitle")}
          </h2>
          <p className="text-[15px] text-muted" style={{ lineHeight: 1.5 }}>
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

        <div className="mt-12 flex flex-wrap items-center justify-center gap-4 text-sm">
          <a
            href={BROWSER_RELEASE_REPOSITORY_URL}
            className="text-muted underline decoration-link-underline underline-offset-2 transition-colors hover:text-foreground hover:decoration-foreground"
          >
            {t("sourceLink")}
          </a>
          {isPlatformDownloadAvailable(otherPlatform) && (
            <Link
              href={PLATFORM_DOWNLOADS[otherPlatform].page}
              className="text-muted underline decoration-link-underline underline-offset-2 transition-colors hover:text-foreground hover:decoration-foreground"
            >
              {t("otherPlatform", {
                platform: t(`${otherPlatform}.name`),
              })}
            </Link>
          )}
          <Link
            href="/"
            className="text-muted underline decoration-link-underline underline-offset-2 transition-colors hover:text-foreground hover:decoration-foreground"
          >
            {t("macLink")}
          </Link>
        </div>
      </main>
    </div>
  );
}

/** Displays the arrow used in the primary download action. */
function DownloadIcon() {
  return (
    <svg
      width="18"
      height="18"
      viewBox="0 0 24 24"
      fill="none"
      stroke="currentColor"
      strokeWidth="2"
      strokeLinecap="round"
      strokeLinejoin="round"
      className="shrink-0"
      aria-hidden="true"
    >
      <path d="M12 3v12" />
      <path d="m7 10 5 5 5-5" />
      <path d="M5 21h14" />
    </svg>
  );
}
