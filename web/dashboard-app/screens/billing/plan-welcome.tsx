"use client";

import { Link } from "@tanstack/react-router";
import { useTranslations } from "next-intl";
import { settingsButtonClass } from "@/dashboard-app/components/settings-ui/styles";

export type WelcomePlan = "go" | "pro" | "max";

/** `?welcome=` after a personal checkout; anything else is no welcome. */
export function welcomePlan(value: unknown): WelcomePlan | null {
  return value === "go" || value === "pro" || value === "max" ? value : null;
}

/** Plan & billing after checkout: what unlocked and the first things to try. */
export function PlanWelcome({ plan }: { readonly plan: WelcomePlan }) {
  const t = useTranslations("dashboard.billing");
  const name = t(`picker.names.${plan}`);
  return (
    <section data-testid="plan-welcome" className="mb-3 border border-foreground p-3">
      <h2 className="text-sm font-medium">{t("welcome.title", { plan: name })}</h2>
      <p className="mt-1 text-xs text-muted">{t("welcome.body")}</p>
      <ul className="mt-2 space-y-1 text-xs text-muted">
        {(t.raw(`picker.features.${plan}`) as string[]).map((line) => <li key={line}>{line}</li>)}
      </ul>
      <div className="mt-3 flex flex-wrap gap-2">
        <Link to="/dashboard/testflight" className={settingsButtonClass("primary", "sm")}>{t("welcome.ios")}</Link>
        <Link to="/dashboard/cloud" className={settingsButtonClass("secondary", "sm")}>{t("welcome.cloud")}</Link>
        <Link to="/dashboard/teams/new" className={settingsButtonClass("secondary", "sm")}>{t("welcome.team")}</Link>
      </div>
    </section>
  );
}

/** A page a checkout returned to: one line, and the way to Plan & billing. */
export function PlanWelcomeBanner({ plan }: { readonly plan: WelcomePlan }) {
  const t = useTranslations("dashboard.billing");
  return (
    <p data-testid="plan-welcome" className="mb-3 border border-foreground p-3 text-xs">
      {t("welcome.banner", { plan: t(`picker.names.${plan}`) })}{" "}
      <Link to="/dashboard/billing" className="underline">{t("welcome.bannerLink")}</Link>
    </p>
  );
}
