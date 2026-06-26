import { useTranslations } from "next-intl";
import { getTranslations } from "next-intl/server";
import { Link } from "../../../i18n/navigation";
import { RevealImage } from "../components/reveal-image";
import { buildAlternates } from "../../../i18n/seo";
import { SiteHeader } from "../components/site-header";
import { BrandLogoLink } from "../components/brand-logo-link";
import { GitHubButton } from "../components/github-button";
import { AppleMark } from "../components/apple-mark";
import {
  ctaButtonBase,
  ctaButtonDefaultSize,
  ctaButtonStyle,
} from "../components/cta-styles";
import iosWorkspaces from "../assets/ios-workspaces.png";
import iosClaude from "../assets/ios-claude.png";
import iosCodex from "../assets/ios-codex.png";
import iosOpencode from "../assets/ios-opencode.png";
import iosPi from "../assets/ios-pi.png";
import iosNvim from "../assets/ios-nvim.png";
import iosVim from "../assets/ios-vim.png";
import iosHtop from "../assets/ios-htop.png";
import iosBtop from "../assets/ios-btop.png";

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
          <a
            href="https://github.com/manaflow-ai/cmux#founders-edition"
            className={`${ctaButtonBase} ${ctaButtonDefaultSize}`}
            style={ctaButtonStyle}
          >
            <AppleMark size={19} />
            {t("ctaBeta")}
          </a>
          <GitHubButton />
        </div>

        {/* Phone */}
        <div
          data-dev="ios-screenshot"
          className="my-14 grid grid-cols-2 gap-4 sm:gap-6"
        >
          <RevealImage
            src={iosWorkspaces}
            alt={t("screenshotAlt")}
            priority
            sizes="(max-width: 640px) 42vw, 336px"
            className="w-full h-auto drop-shadow-[0_24px_56px_rgba(0,0,0,0.5)]"
          />
          <RevealImage
            src={iosClaude}
            alt={t("screenshotAlt")}
            priority
            delay={90}
            sizes="(max-width: 640px) 42vw, 336px"
            className="w-full h-auto drop-shadow-[0_24px_56px_rgba(0,0,0,0.5)]"
          />
        </div>

        {/* Gallery */}
        <section data-dev="ios-gallery" className="-mx-6 sm:mx-0 my-14">
          <h2 className="text-xs font-medium text-muted tracking-tight mb-5 text-center">
            {t("galleryTitle")}
          </h2>
          <div className="grid grid-cols-1 sm:grid-cols-2 gap-4 sm:gap-6 px-6 sm:px-0">
            {(
              [
                [iosClaude, "Claude Code"],
                [iosCodex, "Codex"],
                [iosOpencode, "OpenCode"],
                [iosPi, "pi"],
                [iosNvim, "Neovim"],
                [iosVim, "Vim"],
                [iosHtop, "htop"],
                [iosBtop, "btop"],
              ] as const
            ).map(([src, name], i) => (
              <figure key={name} className="m-0">
                <RevealImage
                  src={src}
                  alt={t("galleryItemAlt", { name })}
                  // Cascade within each row pair so the grid reveals as a wave
                  // rather than all at once.
                  delay={(i % 2) * 90}
                  sizes="(max-width: 640px) 90vw, 336px"
                  className="w-full h-auto drop-shadow-[0_18px_40px_rgba(0,0,0,0.45)]"
                />
                <figcaption className="mt-2.5 text-center text-xs text-muted">
                  {name}
                </figcaption>
              </figure>
            ))}
          </div>
        </section>

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
