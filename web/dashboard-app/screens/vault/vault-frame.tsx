"use client";

import { useTranslations } from "next-intl";
import type { ReactNode } from "react";

/** `/dashboard/vault` frame and header: shown while the summary loads and when it fails. */
export function VaultOverviewFrame({ children }: { readonly children: ReactNode }) {
  const t = useTranslations("vault.overview");
  return (
    <div className="mx-auto w-full max-w-6xl px-3 py-4">
      <div className="mb-4 border-b border-border pb-3">
        <p className="text-xs font-medium text-muted">{t("eyebrow")}</p>
        <h1 className="mt-1 text-sm font-medium">{t("title")}</h1>
        <p className="mt-1 max-w-2xl text-muted">{t("description")}</p>
      </div>
      {children}
    </div>
  );
}
