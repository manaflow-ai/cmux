"use client";

import { useTranslations } from "next-intl";
import { Link } from "../../../i18n/navigation";
import posthog from "posthog-js";
import { ProUpgradeVisibility } from "./pro-upgrade-visibility";

export function NavLinks() {
  const t = useTranslations("nav");
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
        <Link
          href="/pricing"
          onClick={() =>
            posthog.capture("cmuxterm_pricing_nav_clicked", { location: "nav" })
          }
          className="hover:text-foreground transition-colors"
        >
          {t("pricing")}
        </Link>
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
