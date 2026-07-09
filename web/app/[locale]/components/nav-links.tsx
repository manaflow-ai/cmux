"use client";

import { useTranslations } from "next-intl";
import { Link } from "../../../i18n/navigation";
import { captureAnalyticsClick } from "../../lib/analytics";
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
            captureAnalyticsClick("cmuxterm_pricing_nav_clicked", { location: "nav" })
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
        onClick={() => captureAnalyticsClick("cmuxterm_github_clicked", { location: "navbar" })}
        className="hover:text-foreground transition-colors"
      >
        {t("github")}
      </a>
    </>
  );
}
