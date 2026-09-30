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

/** The account service could not confirm the session or team grants. */
export function CoderouterLoadError() {
  const t = useTranslations("dashboard.coderouterAccounts");
  return (
    <section className="border border-border p-3">
      <h2 className="text-sm font-medium">{t("pageErrorTitle")}</h2>
      <p className="mt-1 max-w-2xl text-xs text-muted">{t("pageErrorBody")}</p>
    </section>
  );
}
