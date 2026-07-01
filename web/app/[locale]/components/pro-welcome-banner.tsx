"use client";

import { useTranslations } from "next-intl";
import { useSearchParams } from "next/navigation";

// Reads the ?welcome= state set by /api/billing/confirm and
// /api/billing/checkout so the /pro page itself can stay static.
// Render inside <Suspense> (useSearchParams requirement).
export function ProWelcomeBanner() {
  const t = useTranslations("pro");
  const params = useSearchParams();
  const welcome = params.get("welcome");
  if (!welcome) return null;

  const message =
    welcome === "pending"
      ? t("welcomePending")
      : welcome === "active"
        ? t("welcomeActive")
        : t("welcomeSuccess");

  return (
    <div
      role="status"
      className="mb-8 rounded-lg border border-border bg-code-bg px-4 py-3 text-[15px]"
    >
      {message}
    </div>
  );
}
