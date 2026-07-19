"use client";

import { useLocale, useTranslations } from "next-intl";
import { useSearchParams } from "next/navigation";
import { fallbackContentLocales } from "../../../i18n/locale-availability";
import { ContentLocaleLink } from "./content-locale-link";

// Reads the ?welcome= / ?billing= states set by /api/billing/checkout so the
// /pro page itself can stay static.
// Render inside <Suspense> (useSearchParams requirement).
export function ProWelcomeBanner() {
  const t = useTranslations("pricing");
  const locale = useLocale();
  const params = useSearchParams();
  const welcome = params.get("welcome");
  const billing = params.get("billing");

  const message =
    welcome === "success"
      ? t("welcomeSuccess")
      : welcome === "active"
        ? t("welcomeActive")
        : welcome === "pending"
          ? t("welcomePending")
          : welcome === "team"
            ? t("welcomeTeam")
            : billing === "error"
              ? t("billingError")
              : billing === "unavailable"
                ? t("billingUnavailable")
                : billing === "cancelled"
                  ? t("billingCancelled")
                  : billing === "invalid_plan"
                    ? t("billingInvalidPlan")
                    : null;
  if (!message) return null;

  return (
    <div
      role="status"
      className="mb-8 rounded-lg border border-border bg-code-bg px-4 py-3 text-[15px]"
    >
      {message}
      {welcome === "pending" && (
        <>
          {" "}
          <ContentLocaleLink
            href="/pricing"
            currentLocale={locale}
            contentLocales={fallbackContentLocales}
            className="underline underline-offset-2 decoration-link-underline hover:decoration-foreground transition-colors"
          >
            {t("welcomePendingAction")}
          </ContentLocaleLink>
        </>
      )}
    </div>
  );
}
