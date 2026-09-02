import { Suspense } from "react";
import { getTranslations } from "next-intl/server";
import { cacheLife } from "next/cache";
import { redirect } from "next/navigation";

import { requireDashboardUser } from "@/app/lib/dashboard-auth";
import { isStackConfigured } from "@/app/lib/stack";
import { Link } from "@/i18n/navigation";
import { isAscConfigured } from "@/services/asc/client";
import { testerGroupStatus } from "@/services/asc/testflight";
import { isTestflightEligible } from "@/services/billing/pro";
import { captureAscError } from "@/services/errors";
import { TestflightPageHeader } from "../components/dashboard-page-headers";

// The browser prefetches one private page snapshot. The snapshot is never
// stored on the server, and its header and body commit as one render unit.
export const instant = true;

type SearchParams = {
  testflight?: string | string[];
};

type TestflightStatus = {
  enrolled: boolean;
  state?: string;
  unavailable?: boolean;
};

type PageProps = {
  params: Promise<{ locale: string }>;
  searchParams?: Promise<SearchParams>;
};

export default function DashboardTestflightPage(props: PageProps) {
  if (!isStackConfigured()) {
    redirect("/");
  }

  return (
    <Suspense fallback={null}>
      <ResolvedDashboardTestflightContent {...props} />
    </Suspense>
  );
}

async function ResolvedDashboardTestflightContent({
  params,
  searchParams,
}: PageProps) {
  // Framework promises are not stable cache keys across prerender phases.
  const [{ locale }, query] = await Promise.all([params, searchParams]);
  const testflight = Array.isArray(query?.testflight)
    ? query.testflight[0]
    : query?.testflight;

  return (
    <DashboardTestflightContent locale={locale} testflight={testflight} />
  );
}

export async function DashboardTestflightContent({
  locale,
  testflight,
}: {
  locale: string;
  testflight?: string;
}) {
  "use cache: private";
  cacheLife({ stale: 300 });

  const user = await requireDashboardUser(locale, "/dashboard/testflight");

  const [t, eligible] = await Promise.all([
    getTranslations({ locale, namespace: "dashboard.testflight" }),
    isTestflightEligible(user),
  ]);
  const email = normalizedEmail(user.primaryEmail);
  const status = eligible && email
    ? await loadTestflightStatus(email, user.id)
    : { enrolled: false };
  const banner = testflightBanner(testflight);

  return (
    <div className="mx-auto w-full max-w-5xl px-3 py-4">
      <TestflightPageHeader />
      <div>
        {banner ? (
          <div className="mb-3 border border-border bg-background p-3 text-sm">
            {t(`banners.${banner}`)}
          </div>
        ) : null}

        {!eligible ? (
          <NotEligible t={t} />
        ) : !email ? (
          <NeedsEmail t={t} />
        ) : status.unavailable ? (
          <Unavailable t={t} />
        ) : status.enrolled ? (
          <Enrolled t={t} email={email} state={status.state} />
        ) : (
          <Join t={t} email={email} />
        )}
      </div>
    </div>
  );
}

async function loadTestflightStatus(
  email: string,
  stackUserId: string,
): Promise<TestflightStatus> {
  if (!isAscConfigured()) return { enrolled: false, unavailable: true };
  try {
    return await testerGroupStatus(email);
  } catch (error) {
    captureAscError(error, {
      page: "/dashboard/testflight",
      stackUserId,
      email,
    });
    return { enrolled: false, unavailable: true };
  }
}

function NotEligible({ t }: { t: Awaited<ReturnType<typeof getTranslations>> }) {
  return (
    <section className="border border-border p-3">
      <h2 className="text-sm font-medium">{t("notEligible.title")}</h2>
      <p className="mt-2 max-w-2xl text-muted">{t("notEligible.body")}</p>
      <Link
        href="/pricing"
        className="mt-3 inline-block border border-border bg-background px-3 py-1.5 text-foreground focus-visible:outline focus-visible:outline-1 focus-visible:outline-foreground hover:bg-foreground hover:text-background"
      >
        {t("actions.viewPricing")}
      </Link>
    </section>
  );
}

function NeedsEmail({ t }: { t: Awaited<ReturnType<typeof getTranslations>> }) {
  return (
    <section className="border border-border p-3">
      <h2 className="text-sm font-medium">{t("needsEmail.title")}</h2>
      <p className="mt-2 max-w-2xl text-muted">{t("needsEmail.body")}</p>
    </section>
  );
}

function Unavailable({ t }: { t: Awaited<ReturnType<typeof getTranslations>> }) {
  return (
    <section className="border border-border p-3">
      <h2 className="text-sm font-medium">{t("unavailable.title")}</h2>
      <p className="mt-2 max-w-2xl text-muted">{t("unavailable.body")}</p>
    </section>
  );
}

function Join({
  t,
  email,
}: {
  t: Awaited<ReturnType<typeof getTranslations>>;
  email: string;
}) {
  return (
    <section className="border border-border p-3">
      <h2 className="text-sm font-medium">{t("join.title")}</h2>
      <p className="mt-2 max-w-2xl text-muted">{t("join.body", { email })}</p>
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

function Enrolled({
  t,
  email,
  state,
}: {
  t: Awaited<ReturnType<typeof getTranslations>>;
  email: string;
  state?: string;
}) {
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

function normalizedEmail(email: string | null | undefined): string | null {
  const normalized = email?.trim().toLowerCase();
  return normalized ? normalized : null;
}

function testflightBanner(value: string | undefined) {
  return value === "joined" ||
    value === "left" ||
    value === "error" ||
    value === "ineligible" ||
    value === "needs_email" ||
    value === "unavailable"
    ? value
    : null;
}
