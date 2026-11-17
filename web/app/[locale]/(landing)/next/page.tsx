import { useTranslations } from "next-intl";
import { getTranslations } from "next-intl/server";
import { CMUX_NEXT_NIGHTLY_DMG_URL } from "@/app/lib/nightly-downloads";
import { SiteHeader } from "@/app/[locale]/components/site-header";
import { AppleMark } from "@/app/[locale]/components/apple-mark";
import { GitHubButton } from "@/app/[locale]/components/github-button";
import {
  ctaButtonBase,
  ctaButtonDefaultSize,
  ctaButtonStyle,
} from "@/app/[locale]/components/cta-styles";
import { nightlyDownloadMetadata } from "../nightly-download-page";
import { NextShot } from "./next-shot";

export async function generateMetadata({
  params,
}: {
  params: Promise<{ locale: string }>;
}) {
  const { locale } = await params;
  const meta = await nightlyDownloadMetadata(locale, "next", "/next");
  const t = await getTranslations({ locale, namespace: "next" });
  const images = [
    { url: "/next/hero-dark.webp", width: 1100, height: 720, alt: t("landing.heroAlt") },
  ];
  return { ...meta, openGraph: { ...meta.openGraph, images } };
}

// Same order as the bullets read best: what it is, where you talk to it,
// what it runs, then the tools around the agents.
const FEATURES = [
  "chief",
  "home",
  "agents",
  "floating",
  "search",
  "spaces",
  "browser",
  "machines",
  "history",
  "terminal",
  "sidebar",
  "phone",
] as const;

// Each demo is a real capture of cmux NEXT (light and dark) from the fleet
// capture rig; `shot` is the file stem under /public/next.
const DEMOS = [
  { key: "docked", shot: "docked" },
  { key: "floating", shot: "floating" },
  { key: "agents", shot: "agents" },
  { key: "palette", shot: "palette" },
  { key: "history", shot: "history" },
  { key: "machines", shot: "hosts" },
] as const;

const linkClass =
  "underline underline-offset-2 decoration-link-underline hover:decoration-foreground transition-colors";

/**
 * cmux NEXT landing page. It follows the cmux.com home page layout (one text
 * column, bullet one-liners, a wide product shot) so it can replace the home
 * page when cmux NEXT ships.
 */
export default function NextLandingPage() {
  const t = useTranslations("next");

  const download = (
    <a
      href={CMUX_NEXT_NIGHTLY_DMG_URL}
      className={`${ctaButtonBase} ${ctaButtonDefaultSize}`}
      style={ctaButtonStyle}
    >
      <AppleMark />
      {t("download")}
    </a>
  );

  return (
    <div className="min-h-screen">
      <SiteHeader section="NEXT" />

      <main className="w-full max-w-2xl mx-auto px-6 py-16 sm:py-24">
        <div className="flex items-center gap-4 mb-10">
          <img
            src="/next/icon-96.webp"
            // Decorative: the heading beside it already names the app.
            alt=""
            width={48}
            height={48}
            className="rounded-xl"
          />
          <h1 className="text-2xl font-semibold tracking-tight">cmux NEXT</h1>
        </div>

        <p className="text-lg leading-relaxed mb-3 text-foreground text-balance">
          {t("landing.tagline")}
        </p>
        <p
          className="text-base text-muted text-pretty lg:-mr-32 xl:-mr-48"
          style={{ lineHeight: 1.5 }}
        >
          {t("landing.subtitle")}
        </p>

        <div
          className="flex flex-wrap items-center gap-3"
          style={{ marginTop: 21, marginBottom: 10 }}
        >
          {download}
          <GitHubButton location="next" />
        </div>
        <p className="text-[13px] text-muted mb-4">{t("landing.requirements")}</p>

        <section style={{ paddingTop: 12, paddingBottom: 15 }}>
          <h2 className="text-xs font-medium text-muted tracking-tight mb-3">
            {t("landing.featuresTitle")}
          </h2>
          <ul className="space-y-3 text-[15px]" style={{ lineHeight: 1.275 }}>
            {FEATURES.map((key) => (
              <li key={key} className="flex gap-3">
                <span className="text-muted shrink-0">-</span>
                <span>
                  <strong className="font-medium">
                    {t(`landing.features.${key}.title`)}
                  </strong>{" "}
                  <span className="text-muted">
                    {t(`landing.features.${key}.body`)}
                  </span>
                </span>
              </li>
            ))}
          </ul>
        </section>

        {/* Wide product shot: bleeds past the text column like the home page
            screenshot, capped at the capture's native 1100px width. */}
        <div className="mt-12 mb-16 relative left-1/2 -translate-x-1/2 w-[min(1100px,100vw_-_3rem)]">
          <NextShot name="hero" alt={t("landing.heroAlt")} eager />
        </div>

        <section className="mb-16">
          <h2 className="text-xs font-medium text-muted tracking-tight mb-6">
            {t("landing.demosTitle")}
          </h2>
          <div className="relative left-1/2 -translate-x-1/2 w-[min(1100px,100vw_-_3rem)] grid gap-x-8 gap-y-10 md:grid-cols-2">
            {DEMOS.map(({ key, shot }) => (
              <figure key={key}>
                <NextShot name={shot} alt={t(`landing.demos.${key}.alt`)} />
                <figcaption className="mt-3 text-[15px] text-muted">
                  {t(`landing.demos.${key}.caption`)}
                </figcaption>
              </figure>
            ))}
          </div>
        </section>

        <section id="download" className="mb-10">
          <h2 className="text-xs font-medium text-muted tracking-tight mb-3">
            {t("landing.nightlyTitle")}
          </h2>
          <div className="space-y-3 text-[15px] text-muted" style={{ lineHeight: 1.5 }}>
            <p>{t("landing.nightlyBody")}</p>
            <p>{t("description")}</p>
            <p>
              {t.rich("warning", {
                githubLink: (chunks) => (
                  <a
                    href="https://github.com/manaflow-ai/cmux/issues"
                    target="_blank"
                    rel="noopener noreferrer"
                    className={linkClass}
                  >
                    {chunks}
                  </a>
                ),
                discordLink: (chunks) => (
                  <a
                    href="https://discord.gg/xsgFEVrWCZ"
                    target="_blank"
                    rel="noopener noreferrer"
                    className={linkClass}
                  >
                    {chunks}
                  </a>
                ),
              })}
            </p>
          </div>
        </section>

        <div className="flex flex-wrap items-center justify-center gap-3 mt-12">
          {download}
        </div>
      </main>
    </div>
  );
}
