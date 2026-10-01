"use client";

import { useLocale, useTranslations } from "next-intl";
import { Link } from "../../../i18n/navigation";
import { fallbackContentLocales } from "../../../i18n/locale-availability";
import posthog from "posthog-js";
import { ProUpgradeVisibility } from "./pro-upgrade-visibility";
import { ContentLocaleLink } from "./content-locale-link";

export function NavLinks() {
  const t = useTranslations("nav");
  const locale = useLocale();
  return (
    <>
      <Link
        href="/docs/getting-started"
        className="hover:text-foreground transition-colors"
      >
        {t("docs")}
      </Link>
      <Link
        href="/blog"
        className="hover:text-foreground transition-colors"
      >
        {t("blog")}
      </Link>
      <Link
        href="/docs/changelog"
        className="hover:text-foreground transition-colors"
      >
        {t("changelog")}
      </Link>
      <Link
        href="/community"
        className="hover:text-foreground transition-colors"
      >
        {t("community")}
      </Link>
      <ProUpgradeVisibility>
        <ContentLocaleLink
          href="/pricing"
          currentLocale={locale}
          contentLocales={fallbackContentLocales}
          onClick={() =>
            posthog.capture("cmuxterm_pricing_nav_clicked", { location: "nav" })
          }
          className="hover:text-foreground transition-colors"
        >
          {t("pricing")}
        </ContentLocaleLink>
      </ProUpgradeVisibility>
      <a
        href="https://github.com/manaflow-ai/cmux"
        target="_blank"
        rel="noopener noreferrer"
        onClick={() => posthog.capture("cmuxterm_github_clicked", { location: "navbar" })}
        className="hover:text-foreground transition-colors"
      >
        {t("github")}
      </a>
    </>
  );
}
