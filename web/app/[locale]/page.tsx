import { useTranslations, useLocale } from "next-intl";
import { FadeImage } from "./components/fade-image";
import Balancer from "react-wrap-balancer";
import landingImage from "./assets/landing-image.png";
import { TypingTagline } from "./typing";
import { DownloadButton } from "./components/download-button";
import { GitHubButton } from "./components/github-button";
import { SiteHeader } from "./components/site-header";
import { testimonials, getTestimonialTranslation } from "./testimonials";
import { Link } from "../../i18n/navigation";

export default function Home() {
  return <HomeContent />;
}

function HomeContent() {
  const t = useTranslations("home");
  const tc = useTranslations("common");
  const tt = useTranslations("testimonials");
  const locale = useLocale();

  const linkClass =
    "underline underline-offset-2 decoration-border hover:decoration-foreground transition-colors";

  return (
    <div className="min-h-screen">
      <SiteHeader hideLogo />

      <main className="w-full max-w-2xl mx-auto px-6 py-16 sm:py-24">
        {/* Header */}
        <div className="flex items-center gap-4 mb-10" data-dev="header">
          <img
            src="/logo.png"
            alt="cmux icon"
            width={48}
            height={48}
            className="rounded-xl"
          />
          <h1 className="text-2xl font-semibold tracking-tight">cmux</h1>
        </div>

        {/* Tagline */}
        <p className="text-lg leading-relaxed mb-3 text-foreground">
          {t("taglinePrefix")}
          <TypingTagline />
        </p>
        <p
          className="text-base text-muted"
          data-dev="subtitle"
          style={{ lineHeight: 1.5 }}
        >
          <Balancer>{t("subtitle")}</Balancer>
        </p>

        {/* Download */}
        <div
          className="flex flex-wrap items-center gap-3"
          data-dev="download"
          style={{ marginTop: 21, marginBottom: 16 }}
        >
          <DownloadButton location="hero" />
          <GitHubButton />
        </div>

        {/* Features */}
        <section
          data-dev="features"
          style={{ paddingTop: 12, paddingBottom: 15 }}
        >
          <h2 className="text-xs font-medium text-muted tracking-tight mb-3">
            {t("features")}
          </h2>
          <ul
            className="space-y-3 text-[15px]"
            data-dev="features-ul"
            style={{ lineHeight: 1.275 }}
          >
            {(
              [
                ["verticalTabs", "verticalTabsDesc"],
                ["notificationRings", "notificationRingsDesc"],
                ["inAppBrowser", "inAppBrowserDesc"],
                ["splitPanes", "splitPanesDesc"],
                ["scriptable", "scriptableDesc"],
                ["gpuAccelerated", "gpuAcceleratedDesc"],
                ["lightweight", "lightweightDesc"],
              ] as const
            ).map(([title, desc]) => (
              <li key={title} className="flex gap-3">
                <span className="text-muted shrink-0">-</span>
                <span>
                  <strong className="font-medium">
                    {t(`feature.${title}`)}
                  </strong>
                  <span className="text-muted">{t(`feature.${desc}`)}</span>
                </span>
              </li>
            ))}
            <li className="flex gap-3">
              <span className="text-muted shrink-0">-</span>
              <span>
                <strong className="font-medium">
                  {t("feature.keyboardShortcuts")}
                </strong>
                <span className="text-muted">
                  {t.rich("feature.keyboardShortcutsDesc", {
                    link: (chunks) => (
                      <a
                        href="/docs/keyboard-shortcuts"
                        className={linkClass}
                      >
                        {chunks}
                      </a>
                    ),
                  })}
                </span>
              </span>
            </li>
          </ul>
        </section>

        {/* Screenshot */}
        <div
          data-dev="screenshot"
          className="mb-12 -mx-6 sm:-mx-24 md:-mx-40 lg:-mx-72 xl:-mx-96"
        >
          <FadeImage
            src={landingImage}
            alt="cmux terminal app screenshot"
            priority
            className="w-full rounded-xl"
          />
        </div>

        {/* FAQ */}
        <div data-dev="faq-top-spacer" style={{ height: 0 }} />
        <section data-dev="faq" className="mb-10">
          <h2 className="text-xs font-medium text-muted tracking-tight mb-3">
            {t("faq")}
          </h2>
          <div
            className="space-y-5 text-[15px]"
            style={{ lineHeight: 1.5 }}
          >
            <div>
              <p className="font-medium mb-1">{t("faqGhosttyQ")}</p>
              <p className="text-muted">
                {t.rich("faqGhosttyA", {
                  link: (chunks) => (
                    <a
                      href="https://github.com/ghostty-org/ghostty"
                      className={linkClass}
                    >
                      {chunks}
                    </a>
                  ),
                })}
              </p>
            </div>
            <div>
              <p className="font-medium mb-1">{t("faqPlatformQ")}</p>
              <p className="text-muted">{t("faqPlatformA")}</p>
            </div>
            <div>
              <p className="font-medium mb-1">{t("faqAgentsQ")}</p>
              <p className="text-muted">{t("faqAgentsA")}</p>
            </div>
            <div>
              <p className="font-medium mb-1">{t("faqNotificationsQ")}</p>
              <p className="text-muted">
                {t.rich("faqNotificationsA", {
                  cliLink: (chunks) => (
                    <a href="/docs/notifications" className={linkClass}>
                      {chunks}
                    </a>
                  ),
                  hooksLink: (chunks) => (
                    <a href="/docs/notifications" className={linkClass}>
                      {chunks}
                    </a>
                  ),
                })}
              </p>
            </div>
            <div>
              <p className="font-medium mb-1">{t("faqShortcutsQ")}</p>
              <p className="text-muted">
                {t.rich("faqShortcutsA", {
                  configPath: (chunks) => (
                    <code className="text-xs bg-code-bg px-1.5 py-0.5 rounded">
                      {chunks}
                    </code>
                  ),
                  link: (chunks) => (
                    <a href="/docs/keyboard-shortcuts" className={linkClass}>
                      {chunks}
                    </a>
                  ),
                })}
              </p>
            </div>
            <div>
              <p className="font-medium mb-1">{t("faqTmuxQ")}</p>
              <p className="text-muted">{t("faqTmuxA")}</p>
            </div>
            <div>
              <p className="font-medium mb-1">{t("faqFreeQ")}</p>
              <p className="text-muted">
                {t.rich("faqFreeA", {
                  link: (chunks) => (
                    <a
                      href="https://github.com/manaflow-ai/cmux"
                      className={linkClass}
                    >
                      {chunks}
                    </a>
                  ),
                })}
              </p>
            </div>
          </div>
        </section>

        {/* Community */}
        <section data-dev="community" className="mb-10">
          <h2 className="text-xs font-medium text-muted tracking-tight mb-3">
            {t("communitySection")}
          </h2>
          <ul
            data-dev="community-ul"
            className="text-[15px]"
            style={{
              lineHeight: 1.5,
              display: "flex",
              flexDirection: "column",
              gap: 16,
            }}
          >
            {testimonials.map((item) => {
              const translation = getTestimonialTranslation(item, locale, tt);
              return (
              <li key={item.url}>
                <span>
                  <a
                    href={item.url}
                    target="_blank"
                    rel="noopener noreferrer"
                    className="group"
                  >
                    <span className="text-muted group-hover:text-foreground transition-colors">
                      &quot;{item.text}&quot;
                    </span>
                    {translation && (
                      <span className="text-muted/60 text-xs italic">
                        {" "}
                        — {translation}
                      </span>
                    )}
                  </a>{" "}
                  <a
                    href={item.url}
                    target="_blank"
                    rel="noopener noreferrer"
                    className="inline-flex items-center gap-1 text-muted hover:text-foreground transition-colors"
                  >
                    —
                    {item.avatar && (
                      <img
                        src={item.avatar}
                        alt={item.name}
                        width={16}
                        height={16}
                        className="rounded-full inline-block"
                      />
                    )}
                    {item.name}
                    {"subtitle" in item && item.subtitle
                      ? `, ${item.subtitle}`
                      : ""}
                  </a>
                </span>
              </li>
              );
            })}
          </ul>
        </section>

        {/* Bottom CTA */}
        <div className="flex flex-wrap items-center justify-center gap-3 mt-12">
          <DownloadButton location="bottom" />
          <GitHubButton />
        </div>
        <div className="flex justify-center gap-4 mt-6">
          <Link
            href="/docs"
            className="text-sm text-muted hover:text-foreground transition-colors underline underline-offset-2 decoration-border hover:decoration-foreground"
          >
            {tc("readTheDocs")}
          </Link>
          <Link
            href="/docs/changelog"
            className="text-sm text-muted hover:text-foreground transition-colors underline underline-offset-2 decoration-border hover:decoration-foreground"
          >
            {tc("viewChangelog")}
          </Link>
        </div>
      </main>
    </div>
  );
}
