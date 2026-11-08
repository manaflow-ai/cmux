"use client";

import { Link } from "@tanstack/react-router";
import { useTranslations } from "next-intl";

export function DashboardNotFound() {
  const t = useTranslations("dashboard.notFound");
  return (
    <section className="m-3 max-w-xl border border-border p-4">
      <h1 className="text-sm font-medium">{t("title")}</h1>
      <p className="mt-2 text-sm text-muted">{t("body")}</p>
      <Link to="/dashboard" className="mt-4 inline-block text-sm underline">
        {t("home")}
      </Link>
    </section>
  );
}
