"use client";

import { useSuspenseQuery } from "@tanstack/react-query";
import { useLocale, useTranslations } from "next-intl";
import { Suspense } from "react";

import { DashboardSectionSkeleton } from "../../components/dashboard-skeleton";
import { localeHref } from "../../lib/locale-href";
import { testflightQuery } from "../../queries/testflight";

type Translator = ReturnType<typeof useTranslations>;

const TESTFLIGHT_BANNERS = [
  "joined",
  "left",
  "error",
  "ineligible",
  "needs_email",
  "unavailable",
] as const;

/**
 * `/dashboard/testflight`. The header paints at once; entitlement and
 * enrollment are request-specific and stream in behind the section boundary.
 */
export function TestflightScreen({ testflight }: { testflight?: string }) {
  const t = useTranslations("dashboard.testflight");
  return (
    <div className="mx-auto w-full max-w-5xl px-3 py-4">
      <div className="mb-4 border-b border-border pb-3">
        <p className="text-xs font-medium text-muted">{t("eyebrow")}</p>
        <h1 className="mt-1 text-sm font-medium">{t("title")}</h1>
        <p className="mt-1 max-w-2xl text-muted">{t("description")}</p>
      </div>
      <Suspense fallback={<DashboardSectionSkeleton />}>
        <TestflightContent testflight={testflight} />
      </Suspense>
    </div>
  );
}

export function TestflightContent({ testflight }: { testflight?: string }) {
  const t = useTranslations("dashboard.testflight");
  const { data } = useSuspenseQuery(testflightQuery);
  const banner = testflightBanner(testflight);
  return (
    <div>
      {banner ? (
        <div className="mb-3 border border-border bg-background p-3 text-sm">
          {t(`banners.${banner}`)}
        </div>
      ) : null}
      <TestflightState t={t} eligible={data.eligible} email={data.email} status={data.status} />
    </div>
  );
}

function TestflightState({ t, eligible, email, status }: {
  t: Translator;
  eligible: boolean;
  email: string | null;
  status: { enrolled: boolean; state?: string; unavailable?: boolean };
}) {
  if (!eligible) return <NotEligible t={t} />;
  if (!email) return <NeedsEmail t={t} />;
  if (status.unavailable) return <Unavailable t={t} />;
  if (status.enrolled) return <Enrolled t={t} email={email} state={status.state} />;
  return <Join t={t} email={email} />;
}

function NotEligible({ t }: { t: Translator }) {
  const locale = useLocale();
  return (
    <section className="border border-border p-3">
      <h2 className="text-sm font-medium">{t("notEligible.title")}</h2>
      <p className="mt-2 max-w-2xl text-muted">{t("notEligible.body")}</p>
      <a
        href={localeHref(locale, "/pricing")}
        className="mt-3 inline-block border border-border bg-background px-3 py-1.5 text-foreground focus-visible:outline focus-visible:outline-1 focus-visible:outline-foreground hover:bg-foreground hover:text-background"
      >
        {t("actions.viewPricing")}
      </a>
    </section>
  );
}

function NeedsEmail({ t }: { t: Translator }) {
  return (
    <section className="border border-border p-3">
      <h2 className="text-sm font-medium">{t("needsEmail.title")}</h2>
      <p className="mt-2 max-w-2xl text-muted">{t("needsEmail.body")}</p>
    </section>
  );
}

function Unavailable({ t }: { t: Translator }) {
  return (
    <section className="border border-border p-3">
      <h2 className="text-sm font-medium">{t("unavailable.title")}</h2>
      <p className="mt-2 max-w-2xl text-muted">{t("unavailable.body")}</p>
    </section>
  );
}

function Join({ t, email }: { t: Translator; email: string }) {
  return (
    <section className="border border-border p-3">
      <h2 className="text-sm font-medium">{t("join.title")}</h2>
      <p className="mt-2 max-w-2xl text-muted">{t("join.body", { email })}</p>
      {/* The route 303-redirects back here, so a document POST is enough. */}
      <form method="post" action="/api/testflight" className="mt-4">
        <input type="hidden" name="action" value="join" />
        <button
          type="submit"
          className="border border-border bg-foreground px-3 py-1.5 text-background focus-visible:outline focus-visible:outline-1 focus-visible:outline-foreground"
        >
          {t("actions.join")}
        </button>
      </form>
    </section>
  );
}

function Enrolled({ t, email, state }: { t: Translator; email: string; state?: string }) {
  return (
    <section className="border border-border p-3">
      <h2 className="text-sm font-medium">{t("enrolled.title")}</h2>
      <p className="mt-2 max-w-2xl text-muted">{t("enrolled.body", { email })}</p>
      <div className="mt-4 grid border border-border sm:grid-cols-2">
        <TestflightMetric label={t("details.email")} value={email} />
        <TestflightMetric label={t("details.status")} value={state ?? t("details.enrolled")} />
      </div>
      <p className="mt-3 max-w-2xl text-muted">{t("enrolled.lapseNote")}</p>
      <form method="post" action="/api/testflight" className="mt-4">
        <input type="hidden" name="action" value="leave" />
        <button
          type="submit"
          className="border border-border bg-background px-3 py-1.5 text-foreground focus-visible:outline focus-visible:outline-1 focus-visible:outline-foreground hover:bg-foreground hover:text-background"
        >
          {t("actions.leave")}
        </button>
      </form>
    </section>
  );
}

function TestflightMetric({ label, value }: { label: string; value: string }) {
  return (
    <div className="border-b border-border p-3 sm:border-b-0 sm:border-r">
      <p className="text-xs text-muted">{label}</p>
      <p className="mt-2 font-mono text-xs tabular-nums">{value}</p>
    </div>
  );
}

function testflightBanner(value: string | undefined): (typeof TESTFLIGHT_BANNERS)[number] | null {
  return (TESTFLIGHT_BANNERS as readonly string[]).includes(value ?? "")
    ? value as (typeof TESTFLIGHT_BANNERS)[number]
    : null;
}
