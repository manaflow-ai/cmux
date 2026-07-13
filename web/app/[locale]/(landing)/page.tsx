import { useTranslations, useLocale } from "next-intl";
import { HeroScreenshot } from "@/app/[locale]/components/hero-screenshot";
import { TypingTagline } from "@/app/[locale]/typing";
import { DownloadButton } from "@/app/[locale]/components/download-button";
import { GitHubButton } from "@/app/[locale]/components/github-button";
import { WaitlistCallout } from "@/app/[locale]/components/waitlist-callout";
import { FaqPlatformAnswer } from "@/app/[locale]/components/faq-platform-answer";
import { SiteHeader } from "@/app/[locale]/components/site-header";
import { BrandLogoLink } from "@/app/[locale]/components/brand-logo-link";
import { remoteTmuxDocsLocales } from "@/i18n/locale-availability";
import {
  testimonials,
  getTestimonialSubtitle,
  getTestimonialTranslation,
} from "@/app/[locale]/testimonials";
import { Link } from "@/i18n/navigation";
import NextLink from "next/link";

export default function Home() {
  return <HomeContent />;
}

function HomeContent() {
  const t = useTranslations("home");
  const tc = useTranslations("common");
  const tt = useTranslations("testimonials");
  const tst = useTranslations("testimonialSubtitles");
  const locale = useLocale();
  const hasLocalizedRemoteTmuxDocs = remoteTmuxDocsLocales.includes(
    locale as (typeof remoteTmuxDocsLocales)[number],
  );

  const linkClass =
    "underline underline-offset-2 decoration-link-underline hover:decoration-foreground transition-colors";

  // FAQPage structured data, built from the same FAQ copy rendered below so the
  // Q&As are eligible for Google rich results and AI answer engines.
  const faqKeys = [
    "Ghostty", "Platform", "Ios", "Agents", "Orchestration", "Remote",
    "Notifications", "Scriptable", "Browser", "Skills", "Shortcuts",
    "Customize", "Sessions", "Tmux", "Free", "Support", "Feature",
  ];
  const stripTags = (s: string) => s.replace(/<\/?[a-zA-Z]+>/g, "");
  const faqJsonLd = {
    "@context": "https://schema.org",
    "@type": "FAQPage",
    mainEntity: faqKeys.map((k) => ({
      "@type": "Question",
      name: stripTags(t.raw(`faq${k}Q`) as string),
      acceptedAnswer: {
        "@type": "Answer",
        text: stripTags(t.raw(`faq${k}A`) as string),
      },
    })),
  };
  const faqJsonLdScript = JSON.stringify(faqJsonLd).replace(/</g, "\\u003c");

  return (
    <div className="min-h-screen">
      <script
        type="application/ld+json"
        dangerouslySetInnerHTML={{ __html: faqJsonLdScript }}
      />
      <SiteHeader hideLogo />

      <main className="w-full max-w-2xl mx-auto px-6 py-16 sm:py-24">
        {/* Header */}
        <div className="flex items-center gap-4 mb-10" data-dev="header">
          <BrandLogoLink className="shrink-0">
            <img
              src="/logo.png"
              alt="cmux icon"
              width={48}
              height={48}
              className="rounded-xl"
            />
          </BrandLogoLink>
          <h1 className="text-2xl font-semibold tracking-tight">cmux</h1>
        </div>

        {/* Tagline */}
        <p className="text-lg leading-relaxed mb-3 text-foreground">
          <span className="sr-only">{t("taglineStatic")}</span>
          <span aria-hidden="true">
            {t("taglinePrefix")}
            <TypingTagline />
          </span>
        </p>
        <p
          className="text-base text-muted text-balance lg:-mr-32 xl:-mr-48"
          data-dev="subtitle"
          style={{ lineHeight: 1.5 }}
        >
          {t.rich("subtitle", {
            cliLink: (chunks) => (
              <Link href="/docs/api" className={linkClass}>
                {chunks}
              </Link>
            ),
          })}
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
                ["openSource", "openSourceDesc"],
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
                      <Link
                        href="/docs/keyboard-shortcuts"
                        className={linkClass}
                      >
                        {chunks}
                      </Link>
                    ),
                  })}
                </span>
              </span>
            </li>
            <li className="flex gap-3">
              <span className="text-muted shrink-0">-</span>
              <span>
                <strong className="font-medium">
                  <a
                    href="https://github.com/manaflow-ai/cmux#founders-edition"
                    className={linkClass}
                  >
                    {t("feature.ios")}
                  </a>
                </strong>
                <span className="text-muted">{t("feature.iosDesc")}</span>
              </span>
            </li>
          </ul>
        </section>

        {/* Screenshot: bleeds wider than the text column but stays bounded to
            the viewport so it always fits on screen with a left/right gutter.
            The width tracks the viewport minus a 1.5rem gutter on each side and
            is capped at 90rem; left-1/2 + -translate-x-1/2 keeps it centered
            over the narrower text column. */}
        <div
          data-dev="screenshot"
          className="mt-12 mb-12 relative left-1/2 -translate-x-1/2 w-[min(90rem,100vw_-_3rem)]"
        >
          <HeroScreenshot />
        </div>

        {/* FAQ */}
        <div data-dev="faq-top-spacer" style={{ height: 32 }} />
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
              <FaqPlatformAnswer linkClass={linkClass} />
            </div>
            <div>
              <p className="font-medium mb-1">{t("faqIosQ")}</p>
              <p className="text-muted">
                {t.rich("faqIosA", {
                  foundersLink: (chunks) => (
                    <a
                      href="https://github.com/manaflow-ai/cmux#founders-edition"
                      className={linkClass}
                    >
                      {chunks}
                    </a>
                  ),
                })}
              </p>
            </div>
            <div>
              <p className="font-medium mb-1">{t("faqAgentsQ")}</p>
              <p className="text-muted">{t("faqAgentsA")}</p>
            </div>
            <div>
              <p className="font-medium mb-1">{t("faqOrchestrationQ")}</p>
              <p className="text-muted">
                {t.rich("faqOrchestrationA", {
                  teamsLink: (chunks) => (
                    <Link
                      href="/docs/agent-integrations/claude-code-teams"
                      className={linkClass}
                    >
                      {chunks}
                    </Link>
                  ),
                  omoLink: (chunks) => (
                    <Link
                      href="/docs/agent-integrations/oh-my-opencode"
                      className={linkClass}
                    >
                      {chunks}
                    </Link>
                  ),
                })}
              </p>
            </div>
            <div>
              <p className="font-medium mb-1">{t("faqRemoteQ")}</p>
              <p className="text-muted">
                {t.rich("faqRemoteA", {
                  link: (chunks) => (
                    <Link href="/docs/ssh" className={linkClass}>
                      {chunks}
                    </Link>
                  ),
                })}
              </p>
            </div>
            <div>
              <p className="font-medium mb-1">{t("faqNotificationsQ")}</p>
              <p className="text-muted">
                {t.rich("faqNotificationsA", {
                  cliLink: (chunks) => (
                    <Link href="/docs/notifications#cli-usage" className={linkClass}>
                      {chunks}
                    </Link>
                  ),
                  hooksLink: (chunks) => (
                    <Link href="/docs/notifications#integration-examples" className={linkClass}>
                      {chunks}
                    </Link>
                  ),
                })}
              </p>
            </div>
            <div>
              <p className="font-medium mb-1">{t("faqScriptableQ")}</p>
              <p className="text-muted">
                {t.rich("faqScriptableA", {
                  cliLink: (chunks) => (
                    <Link href="/docs/api" className={linkClass}>
                      {chunks}
                    </Link>
                  ),
                  browserLink: (chunks) => (
                    <Link href="/docs/browser-automation" className={linkClass}>
                      {chunks}
                    </Link>
                  ),
                })}
              </p>
            </div>
            <div>
              <p className="font-medium mb-1">{t("faqBrowserQ")}</p>
              <p className="text-muted">
                {t.rich("faqBrowserA", {
                  link: (chunks) => (
                    <Link href="/docs/browser-automation" className={linkClass}>
                      {chunks}
                    </Link>
                  ),
                })}
              </p>
            </div>
            <div>
              <p className="font-medium mb-1">{t("faqSkillsQ")}</p>
              <p className="text-muted">
                {t.rich("faqSkillsA", {
                  skillsLink: (chunks) => (
                    <a
                      href="https://github.com/manaflow-ai/cmux-skills"
                      className={linkClass}
                    >
                      {chunks}
                    </a>
                  ),
                  link: (chunks) => (
                    <Link href="/docs/skills" className={linkClass}>
                      {chunks}
                    </Link>
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
                    <Link href="/docs/keyboard-shortcuts" className={linkClass}>
                      {chunks}
                    </Link>
                  ),
                })}
              </p>
            </div>
            <div>
              <p className="font-medium mb-1">{t("faqCustomizeQ")}</p>
              <p className="text-muted">
                {t.rich("faqCustomizeA", {
                  path: (chunks) => (
                    <code className="text-xs bg-code-bg px-1.5 py-0.5 rounded">
                      {chunks}
                    </code>
                  ),
                  shortcutsLink: (chunks) => (
                    <Link href="/docs/keyboard-shortcuts" className={linkClass}>
                      {chunks}
                    </Link>
                  ),
                  link: (chunks) => (
                    <Link href="/docs/configuration" className={linkClass}>
                      {chunks}
                    </Link>
                  ),
                })}
              </p>
            </div>
            <div>
              <p className="font-medium mb-1">{t("faqSessionsQ")}</p>
              <p className="text-muted">
                {t.rich("faqSessionsA", {
                  link: (chunks) => (
                    <Link href="/docs/session-restore" className={linkClass}>
                      {chunks}
                    </Link>
                  ),
                })}
              </p>
            </div>
            <div>
              <p className="font-medium mb-1">{t("faqTmuxQ")}</p>
              <p className="text-muted">
                {t.rich("faqTmuxA", {
                  link: (chunks) => (
                    hasLocalizedRemoteTmuxDocs ? (
                      <Link href="/docs/remote-tmux" className={linkClass}>
                        {chunks}
                      </Link>
                    ) : (
                      <NextLink href="/docs/remote-tmux" className={linkClass}>
                        {chunks}
                      </NextLink>
                    )
                  ),
                })}
              </p>
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
            <div>
              <p className="font-medium mb-1">{t("faqSupportQ")}</p>
              <p className="text-muted">
                {t.rich("faqSupportA", {
                  foundersLink: (chunks) => (
                    <a
                      href="https://github.com/manaflow-ai/cmux#founders-edition"
                      className={linkClass}
                    >
                      {chunks}
                    </a>
                  ),
                })}
              </p>
            </div>
            <div>
              <p className="font-medium mb-1">{t("faqFeatureQ")}</p>
              <p className="text-muted">
                {t.rich("faqFeatureA", {
                  issuesLink: (chunks) => (
                    <a
                      href="https://github.com/manaflow-ai/cmux/issues"
                      className={linkClass}
                    >
                      {chunks}
                    </a>
                  ),
                  prLink: (chunks) => (
                    <a
                      href="https://github.com/manaflow-ai/cmux/pulls"
                      className={linkClass}
                    >
                      {chunks}
                    </a>
                  ),
                  mailLink: (chunks) => (
                    <a
                      href="mailto:founders@manaflow.com?subject=%5Bcmux%20feature%20request%20landing%5D&body=Hi%20cmux%20team%2C%20"
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
              const subtitle = getTestimonialSubtitle(item, tst);
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
                        loading="lazy"
                        decoding="async"
                        className="rounded-full inline-block object-cover"
                      />
                    )}
                    {item.name}
                    {subtitle ? `, ${subtitle}` : ""}
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
        <div className="mt-3 flex justify-center">
          <WaitlistCallout location="bottom" />
        </div>
        <div className="flex justify-center gap-4 mt-6">
          <Link
            href="/docs/getting-started"
            className="text-sm text-muted hover:text-foreground transition-colors underline underline-offset-2 decoration-link-underline hover:decoration-foreground"
          >
            {tc("readTheDocs")}
          </Link>
          <Link
            href="/docs/changelog"
            className="text-sm text-muted hover:text-foreground transition-colors underline underline-offset-2 decoration-link-underline hover:decoration-foreground"
          >
            {tc("viewChangelog")}
          </Link>
        </div>
      </main>
    </div>
  );
}
