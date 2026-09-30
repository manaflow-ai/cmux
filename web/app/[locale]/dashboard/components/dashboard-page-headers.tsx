"use client";

import { useTranslations } from "next-intl";

export function CoderouterPageHeader() {
  const t = useTranslations("dashboard.coderouter");

  return <DashboardPageHeader title={t("title")} description={t("description")} />;
}

export function TestflightPageHeader() {
  const t = useTranslations("dashboard.testflight");

  return (
    <DashboardPageHeader
      eyebrow={t("eyebrow")}
      title={t("title")}
      description={t("description")}
    />
  );
}

function DashboardPageHeader({
  eyebrow,
  title,
  description,
}: {
  eyebrow?: string;
  title: string;
  description: string;
}) {
  return (
    <div className="mb-4 border-b border-border pb-3">
      {eyebrow ? <p className="text-xs font-medium text-muted">{eyebrow}</p> : null}
      <h1 className={eyebrow ? "mt-1 text-sm font-medium" : "text-sm font-medium"}>
        {title}
      </h1>
      <p className="mt-1 max-w-2xl text-muted">{description}</p>
    </div>
  );
}
