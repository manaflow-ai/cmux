"use client";

import { useTranslations } from "next-intl";
import type { ReactNode } from "react";

/** Page frame and header. Rendered while the overview loads and on failure. */
export function CoderouterPageFrame({ children }: { readonly children: ReactNode }) {
  const t = useTranslations("dashboard.coderouter");
  return (
    <div className="mx-auto w-full max-w-5xl px-3 py-4">
      <div className="mb-4 border-b border-border pb-3">
        <h1 className="text-sm font-medium">{t("title")}</h1>
        <p className="mt-1 max-w-2xl text-muted">{t("description")}</p>
      </div>
      {children}
    </div>
  );
}
