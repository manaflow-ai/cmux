"use client";

import { useTranslations } from "next-intl";
import { useSearchParams } from "next/navigation";

// Reads the ?welcome= / ?billing= states set by /api/billing/checkout and
// /api/billing/confirm so the /pro page itself can stay static.
// Render inside <Suspense> (useSearchParams requirement).
export function ProWelcomeBanner() {
  const t = useTranslations("pro");
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
          : billing === "error"
            ? t("billingError")
            : billing === "unavailable"
              ? t("billingUnavailable")
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
          <a
            href="/api/billing/confirm"
            className="underline underline-offset-2 decoration-border hover:decoration-foreground transition-colors"
          >
            {t("welcomePendingAction")}
          </a>
        </>
      )}
    </div>
  );
}
