"use client";

import { type QueryClient, type QueryObserverResult, useQuery, useQueryClient } from "@tanstack/react-query";
import { Link, useLocation } from "@tanstack/react-router";
import { useLocale, useTranslations } from "next-intl";
import { localeHref } from "../lib/locale-href";
import { planQuery } from "../queries/billing";
import { personalCheckoutHref } from "../screens/billing/checkout-links";
import { PlanWelcomeBanner, welcomePlan } from "../screens/billing/plan-welcome";
import { settingsButtonClass } from "./settings-ui/styles";

export type ProFeature = "cloud" | "testflight" | "mobileDevices";

/**
 * The plan query as RequiresPro observes it. An invalidation, and the success
 * or failure of the reload after it, must each re-render the prompt, even when
 * the plan comes back unchanged; `data` alone does not change on any of them.
 */
export const planPromptQuery = {
  ...planQuery,
  notifyOnChangeProps: ["data", "isStale", "isFetching", "dataUpdatedAt", "errorUpdatedAt"] as Array<keyof QueryObserverResult>,
};

/**
 * A team switch or checkout invalidates the plan: the cached answer may be the
 * previous team's until a reload succeeds, including when that reload fails.
 * A routine focus refetch does not invalidate, so it keeps the current prompt.
 */
export function planPromptOutdated(queryClient: QueryClient): boolean {
  return queryClient.getQueryState(planQuery.queryKey)?.isInvalidated === true;
}

/**
 * On a page that needs a paid plan: for a Free viewer, what the page needs
 * and Upgrade, which returns here after checkout; after that checkout, the
 * welcome line once the plan confirms it. Nothing while the plan is loading
 * or failed, so the page itself never waits on it.
 */
export function RequiresPro({ feature }: { readonly feature: ProFeature }) {
  const t = useTranslations("dashboard.upgrade");
  const locale = useLocale();
  const location = useLocation();
  const queryClient = useQueryClient();
  const plan = useQuery(planPromptQuery);
  const welcome = welcomePlan((location.search as Record<string, unknown>).welcome);
  if (planPromptOutdated(queryClient) || !plan.data) return null;
  // The welcome shows only once the plan confirms the upgrade; a stale
  // ?welcome link must not hide the prompt from a Free viewer.
  if (plan.data.isPro) return welcome ? <PlanWelcomeBanner plan={welcome} /> : null;
  // Team pays for Cloud access separately from each member's personal plan.
  if (feature === "cloud" && plan.data.teamPlanId === "team") return null;
  return (
    <section data-testid="requires-pro" className="mb-3 flex flex-wrap items-start justify-between gap-3 border border-border p-3">
      <div className="min-w-0 flex-1">
        <h2 className="text-sm font-medium">{t("title")}</h2>
        <p className="mt-1 max-w-2xl text-xs text-muted">{t(feature)}</p>
      </div>
      <div className="flex shrink-0 flex-wrap gap-2">
        {/* Checkout redirects to Stripe: a full document navigation. */}
        <a href={personalCheckoutHref("pro", localeHref(locale, location.pathname))} className={settingsButtonClass("primary", "sm")}>
          {t("action")}
        </a>
        <Link to="/dashboard/billing" className={settingsButtonClass("secondary", "sm")}>{t("comparePlans")}</Link>
      </div>
    </section>
  );
}
