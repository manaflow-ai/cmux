import { useTranslations } from "next-intl";
import { getTranslations } from "next-intl/server";
import Image from "next/image";
import { Link } from "../../../i18n/navigation";
import { buildAlternates } from "../../../i18n/seo";
import { SiteHeader } from "../components/site-header";
import { BrandLogoLink } from "../components/brand-logo-link";
import { GitHubButton } from "../components/github-button";
import phoneImage from "../assets/landing-iphone.png";

export async function generateMetadata({
  params,
}: {
  params: Promise<{ locale: string }>;
}) {
  const { locale } = await params;
  const t = await getTranslations({ locale, namespace: "ios" });
  return {
    title: t("metaTitle"),
    description: t("metaDescription"),
    alternates: buildAlternates(locale, "/ios"),
  };
}

export default function IosLanding() {
  const t = useTranslations("ios");

  const linkClass =
    "underline underline-offset-2 decoration-border hover:decoration-foreground transition-colors";

  const features = [
    ["realtimeSync", "realtimeSyncDesc"],
    ["byoNetwork", "byoNetworkDesc"],
    ["verticalTabs", "verticalTabsDesc"],
    ["notifications", "notificationsDesc"],
    ["keyboard", "keyboardDesc"],
    ["native", "nativeDesc"],
  ] as const;

  return (
    <div className="min-h-screen">
      <SiteHeader hideLogo />

      <main className="w-full max-w-2xl mx-auto px-6 py-16 sm:py-24">
        {/* Header */}
        <div className="flex items-center gap-4 mb-10" data-dev="ios-header">
          <BrandLogoLink className="shrink-0">
            <img
              src="/logo.png"
              alt="cmux icon"
              width={48}
              height={48}
              className="rounded-xl"
            />
          </BrandLogoLink>
          <h1 className="text-2xl font-semibold tracking-tight">
            {t("title")}
          </h1>
        </div>

        {/* Tagline */}
        <p className="text-lg leading-relaxed mb-3 text-foreground">
          {t("tagline")}
        </p>
        <p className="text-base text-muted" style={{ lineHeight: 1.5 }}>
          {t("subtitle")}
        </p>

        {/* CTA */}
        <div
          className="flex flex-wrap items-center gap-3"
          data-dev="ios-cta"
          style={{ marginTop: 21, marginBottom: 16 }}
        >
          <Link
            href="/docs/ios"
            className="inline-flex items-center gap-2 rounded-lg bg-foreground text-background px-4 py-2 text-sm font-medium hover:opacity-90 transition-opacity"
          >
            {t("ctaBeta")}
          </Link>
          <GitHubButton />
        </div>

        {/* Phone */}
        <div
          data-dev="ios-screenshot"
          className="my-14 flex justify-center"
        >
          <Image
            src={phoneImage}
            alt={t("screenshotAlt")}
            priority
            sizes="(max-width: 640px) 70vw, 320px"
            className="w-[64%] max-w-[320px] h-auto drop-shadow-[0_30px_70px_rgba(0,0,0,0.55)]"
          />
        </div>

        {/* Features */}
        <section data-dev="ios-features" style={{ paddingBottom: 15 }}>
          <h2 className="text-xs font-medium text-muted tracking-tight mb-3">
            {t("features")}
          </h2>
          <ul
            className="space-y-3 text-[15px]"
            style={{ lineHeight: 1.275 }}
          >
            {features.map(([title, desc]) => (
              <li key={title} className="flex gap-3">
                <span className="text-muted shrink-0">-</span>
                <span>
                  <strong className="font-medium">{t(title)}</strong>
                  <span className="text-muted">{t(desc)}</span>
                </span>
              </li>
            ))}
          </ul>
        </section>

        {/* How it works */}
        <section data-dev="ios-how" className="mt-8">
          <h2 className="text-xs font-medium text-muted tracking-tight mb-3">
            {t("howTitle")}
          </h2>
          <p className="text-[15px] text-muted" style={{ lineHeight: 1.5 }}>
            {t("howBody")}
          </p>
        </section>

        {/* Bottom links */}
        <div className="flex justify-center gap-4 mt-12">
          <Link href="/docs/ios" className={`text-sm text-muted hover:text-foreground transition-colors ${linkClass}`}>
            {t("ctaDocs")}
          </Link>
          <Link href="/" className={`text-sm text-muted hover:text-foreground transition-colors ${linkClass}`}>
            {t("backToMac")}
          </Link>
        </div>
      </main>
    </div>
  );
}
