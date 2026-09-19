"use client";

import {
  createRootRouteWithContext,
  createRoute,
  createRouter,
  createMemoryHistory,
  Outlet,
  useLocation,
  RouterProvider,
  Link as TanStackLink,
  redirect,
} from "@tanstack/react-router";
import { QueryClient, QueryClientProvider, useMutation, useQueryClient, useSuspenseQuery } from "@tanstack/react-query";
import { AccountSettings } from "@stackframe/stack";
import { useTranslations } from "next-intl";
import { useEffect, useRef, useState } from "react";
import { z } from "zod";

import { orpc } from "@/orpc/query";
import { Link as LocalizedLink } from "@/i18n/navigation";
import { DashboardShell } from "./dashboard-shell";
import { CloudDeviceActions } from "./cloud/device-actions";
import { SessionsTable } from "./vault/sessions/sessions-table";
import { CopyButton } from "./vault/copy-button";
import { TranscriptViewer } from "./vault/sessions/[id]/transcript-viewer";
import { ApproveForm } from "./vault/cli-auth/approve-form";
import {
  CoderouterAccountsSection,
  type ClaudeAccountsState,
  type NativeAccountsState,
  type SharedAccountsState,
} from "./components/coderouter-accounts";
import type { ClaudeAccountDescription } from "@/services/coderouter/claudeUpstream";
import type { CodeRouterAccountSummary } from "@/services/coderouter/types";
import type { SubrouterAccount } from "@/services/subrouter/types";
import { formatBytes, formatDate, truncateMiddle } from "@/services/vault/format";

export type DashboardRouterContext = {
  queryClient: QueryClient;
  vaultEnabled: boolean;
  account: React.ReactNode;
  initialContent: React.ReactNode;
  locale: string;
};

const rootRoute = createRootRouteWithContext<DashboardRouterContext>()({
  component: DashboardRouterRoot,
  notFoundComponent: DashboardRouterNotFound,
  loader: ({ context }) => {
    // Start the identity query without delaying the shell. AccountPlanBadge
    // and future route components consume the same QueryClient cache.
    void context.queryClient
      .prefetchQuery(orpc.account.me.queryOptions())
      .catch(() => undefined);
  },
});

function routeSlot() {
  return <DashboardLegacyRouteBridge />;
}

const indexRoute = createRoute({ getParentRoute: () => rootRoute, path: "/", component: DashboardHomeRoute });
const cloudRoute = createRoute({ getParentRoute: () => rootRoute, path: "/cloud", component: DashboardCloudRoute });
const coderouterRoute = createRoute({
  getParentRoute: () => rootRoute,
  path: "/coderouter",
  validateSearch: z.object({ team: z.string().optional() }),
  component: DashboardCoderouterRoute,
});
const testflightRoute = createRoute({
  getParentRoute: () => rootRoute,
  path: "/testflight",
  validateSearch: z.object({ testflight: z.string().optional() }),
  component: DashboardTestflightRoute,
});
const billingRoute = createRoute({
  getParentRoute: () => rootRoute,
  path: "/billing",
  validateSearch: z.object({ billing: z.string().optional(), interval: z.string().optional() }),
  component: DashboardBillingRoute,
});
const billingSuccessRoute = createRoute({
  getParentRoute: () => rootRoute,
  path: "/billing/success",
  component: routeSlot,
});
const teamRoute = createRoute({ getParentRoute: () => rootRoute, path: "/team", component: DashboardTeamRoute });
const vaultRoute = createRoute({ getParentRoute: () => rootRoute, path: "/vault", component: DashboardVaultOverviewRoute });
const vaultSessionsRoute = createRoute({
  getParentRoute: () => rootRoute,
  path: "/vault/sessions",
  validateSearch: z.object({ q: z.string().optional(), cursor: z.string().optional(), before: z.string().optional() }),
  component: DashboardVaultSessionsRoute,
});
const vaultSessionRoute = createRoute({ getParentRoute: () => rootRoute, path: "/vault/sessions/$id", component: DashboardVaultSessionRoute });
const vaultCliAuthRoute = createRoute({
  getParentRoute: () => rootRoute,
  path: "/vault/cli-auth",
  validateSearch: z.object({ code: z.string().optional() }),
  component: DashboardVaultCliAuthRoute,
});
const navigationFixtureRoute = createRoute({ getParentRoute: () => rootRoute, path: "/navigation-fixture", component: routeSlot });
const legacySubrouterRoute = createRoute({
  getParentRoute: () => rootRoute,
  path: "/subrouter",
  validateSearch: z.object({ team: z.string().optional() }),
  beforeLoad: ({ search }) => {
    throw redirect({ to: "/coderouter", search });
  },
  component: routeSlot,
});
const legacyAiAccountsRoute = createRoute({
  getParentRoute: () => rootRoute,
  path: "/ai-accounts",
  validateSearch: z.object({ team: z.string().optional() }),
  beforeLoad: ({ search }) => {
    throw redirect({ to: "/coderouter", search });
  },
  component: routeSlot,
});

const routeTree = rootRoute.addChildren([
  indexRoute,
  cloudRoute,
  coderouterRoute,
  testflightRoute,
  billingRoute,
  billingSuccessRoute,
  teamRoute,
  vaultRoute,
  vaultSessionsRoute,
  vaultSessionRoute,
  vaultCliAuthRoute,
  navigationFixtureRoute,
  legacySubrouterRoute,
  legacyAiAccountsRoute,
]);

function DashboardRouterRoot() {
  const context = rootRoute.useRouteContext();
  const location = useLocation();

  return (
    <DashboardShell
      vaultEnabled={context.vaultEnabled}
      account={context.account}
      routerEnabled
      currentPathname={location.pathname}
    >
      <Outlet />
    </DashboardShell>
  );
}

function DashboardHomeRoute() {
  const t = useTranslations("dashboard.home");
  const { vaultEnabled } = rootRoute.useRouteContext();
  const products = [
    {
      href: "/cloud",
      name: t("cloudName"),
      description: t("cloudDescription"),
      link: t("cloudLink"),
    },
    {
      href: "/coderouter",
      name: t("coderouterName"),
      description: t("coderouterDescription"),
      link: t("coderouterLink"),
    },
    {
      href: "/testflight",
      name: t("iosAppName"),
      description: t("iosAppDescription"),
      link: t("iosLink"),
    },
  ];
  if (vaultEnabled) {
    products.unshift({
      href: "/vault",
      name: t("vaultName"),
      description: t("vaultDescription"),
      link: t("vaultLink"),
    });
  }

  return (
    <div data-testid="dashboard-router-home" className="mx-auto w-full max-w-5xl px-3 py-4">
      <div className="mb-4 border-b border-border pb-3">
        <h1 className="text-sm font-medium">{t("title")}</h1>
        <p className="mt-1 max-w-2xl text-muted">{t("description")}</p>
      </div>
      <div className="grid gap-3 md:grid-cols-2">
        {products.map((product) => (
          <section key={product.href} className="border border-border p-3">
            <h2 className="text-sm font-medium">{product.name}</h2>
            <p className="mt-2 text-muted">{product.description}</p>
            <TanStackLink
              to={product.href}
              className="mt-3 inline-block border border-border bg-background px-3 py-1.5 text-foreground focus-visible:outline focus-visible:outline-1 focus-visible:outline-foreground hover:bg-foreground hover:text-background"
            >
              {product.link}
            </TanStackLink>
          </section>
        ))}
      </div>
    </div>
  );
}

function DashboardCloudRoute() {
  const t = useTranslations("dashboard.cloud");
  const { locale } = rootRoute.useRouteContext();
  const { data: devices } = useSuspenseQuery(orpc.dashboard.cloud.devices.queryOptions());
  const dates = new Intl.DateTimeFormat(locale, { dateStyle: "medium", timeStyle: "short" });

  return (
    <div data-testid="dashboard-router-cloud" className="mx-auto w-full max-w-5xl px-3 py-4">
      <div className="mb-4 border-b border-border pb-3">
        <h1 className="text-sm font-medium">{t("title")}</h1>
        <p className="mt-1 max-w-2xl text-muted">{t("description")}</p>
      </div>
      {devices.length === 0 ? (
        <p className="border border-border p-3 text-muted">{t("empty")}</p>
      ) : (
        <div className="space-y-3">
          {devices.map((device) => (
            <section key={device.id} className="border border-border p-3">
              <div className="flex flex-wrap items-start justify-between gap-3">
                <div>
                  <h2 className="font-medium">{device.name}</h2>
                  <p className="mt-1 text-xs text-muted">
                    {[device.modelIdentifier, device.osVersion && `macOS ${device.osVersion}`, device.architecture]
                      .filter(Boolean)
                      .join(" · ")}
                  </p>
                </div>
                <CloudDeviceActions id={device.id} name={device.name} />
              </div>
              <dl className="mt-4 grid gap-3 text-xs sm:grid-cols-2 lg:grid-cols-4">
                <DeviceFact label={t("cmux")} value={[device.cmuxChannel, device.cmuxVersion, device.cmuxBuild && `(${device.cmuxBuild})`].filter(Boolean).join(" ") || t("unknown")} />
                <DeviceFact label={t("access")} value={device.tunnelPurposes.length ? device.tunnelPurposes.map((purpose) => t(`purpose.${purpose}`)).join(", ") : t("none")} />
                <DeviceFact label={t("lastContact")} value={dates.format(new Date(device.lastControlPlaneAt))} />
                <DeviceFact label={t("deviceId")} value={`…${device.deviceId.slice(-8)}`} />
              </dl>
            </section>
          ))}
        </div>
      )}
    </div>
  );
}

function DashboardTeamRoute() {
  return (
    <div data-testid="dashboard-router-team" className="w-full px-3 py-4">
      <AccountSettings />
    </div>
  );
}

function DashboardVaultOverviewRoute() {
  const t = useTranslations("vault.overview");
  const { locale } = rootRoute.useRouteContext();
  const { data } = useSuspenseQuery(orpc.dashboard.vault.overview.queryOptions());
  const agentCounts = [...data.rows]
    .sort((a, b) => b.sessionCount - a.sessionCount)
    .map((row) => `${row.sessionCount.toLocaleString(locale)} ${row.agent}`)
    .join(" · ");

  return (
    <div data-testid="dashboard-router-vault" className="mx-auto w-full max-w-6xl px-3 py-4">
      <div className="mb-4 border-b border-border pb-3">
        <p className="text-xs font-medium text-muted">{t("eyebrow")}</p>
        <h1 className="mt-1 text-sm font-medium">{t("title")}</h1>
        <p className="mt-1 max-w-2xl text-muted">{t("description")}</p>
      </div>
      {data.rows.length === 0 ? (
        <div className="border border-border p-3"><h2 className="text-sm font-medium">{t("emptyTitle")}</h2><p className="mt-1 text-muted">{t("emptyBody")}</p><code className="mt-3 inline-block border border-border bg-code-bg px-3 py-1.5 font-mono text-xs">cmux-vault sync</code></div>
      ) : (
        <>
          <div className="grid border border-border sm:grid-cols-2 lg:grid-cols-4">
            <VaultMetric label={t("totalSessions")} value={data.totals.sessionCount.toLocaleString(locale)} />
            <VaultMetric label={t("totalRawBytes")} value={formatBytes(data.totals.rawBytes, locale)} />
            <VaultMetric label={t("totalCompressedBytes")} value={formatBytes(data.totals.compressedBytes, locale)} />
            <VaultMetric label={t("latestUpload")} value={data.totals.lastUploadedAt ? formatDate(new Date(data.totals.lastUploadedAt), locale) : t("never")} />
          </div>
          <p className="mt-2 font-mono text-xs text-muted">{agentCounts}</p>
        </>
      )}
    </div>
  );
}

function VaultMetric({ label, value }: { label: string; value: string }) {
  return <div className="border-b border-border p-3 sm:border-r lg:border-b-0"><p className="text-xs text-muted">{label}</p><p className="mt-2 font-mono text-xs tabular-nums">{value}</p></div>;
}

function DashboardVaultSessionsRoute() {
  const location = useLocation();
  const params = new URLSearchParams(location.search);
  const q = params.get("q") ?? "";
  const cursor = params.get("cursor") ?? undefined;
  const before = params.get("before") ?? undefined;
  const { data } = useSuspenseQuery(orpc.dashboard.vault.sessions.queryOptions({
    input: { q: q || undefined, cursor, before },
  }));

  return (
    <SessionsTable
      initialQuery={q}
      initialRows={data.sessions}
      initialNextCursor={data.nextCursor ?? null}
      initialNowIso={new Date().toISOString()}
    />
  );
}

function DashboardVaultSessionRoute() {
  const t = useTranslations("vault.detail");
  const { locale } = rootRoute.useRouteContext();
  const location = useLocation();
  const id = decodeURIComponent(location.pathname.split("/").at(-1) ?? "");
  const { data } = useSuspenseQuery(orpc.dashboard.vault.session.queryOptions({ input: { id } }));
  const cwd = data.cwd ?? t("unknownCwd");
  const resumeCommand = `cmux-vault resume ${data.agentSessionId}`;

  return (
    <div className="relative h-[calc(100vh-2.75rem)] min-h-0 overflow-hidden bg-background">
      <LocalizedLink href="/dashboard/vault/sessions" className="absolute left-4 top-4 z-10 border border-border bg-background px-3 py-1.5 text-foreground">{t("backToSessions")}</LocalizedLink>
      <aside className="absolute right-4 top-4 z-10 w-80 max-w-[calc(100%-2rem)] border border-border bg-background">
        <details open>
          <summary className="cursor-pointer px-3 py-2 font-medium">{t("detailsSummary")}</summary>
          <div className="max-h-[calc(100vh-6rem)] overflow-y-auto border-t border-border p-3 font-mono text-xs">
            <div className="grid gap-3">
              <div className="grid gap-2"><div className="flex min-w-0 items-center gap-2"><span className="border border-border px-2 py-1 font-medium">{data.agent}</span><span className="min-w-0 truncate" title={data.agentSessionId}>{data.agentSessionId}</span></div><CopyButton value={data.agentSessionId} label={t("copySessionId")} copiedLabel={t("copiedSessionId")} /></div>
              <VaultMetadata label={t("cwd")} value={cwd} />
              <VaultMetadata label={t("rawSize")} value={formatBytes(data.sizeBytes, locale)} />
              <VaultMetadata label={t("compressedSize")} value={data.compressedSizeBytes == null ? t("unknownSize") : formatBytes(data.compressedSizeBytes, locale)} />
              <VaultMetadata label={t("firstUploaded")} value={formatDate(new Date(data.firstUploadedAt), locale)} />
              <VaultMetadata label={t("lastUploaded")} value={formatDate(new Date(data.lastUploadedAt), locale)} />
              <div className="grid gap-2"><code className="block overflow-x-auto border border-border bg-code-bg px-3 py-1.5">{resumeCommand}</code><CopyButton value={resumeCommand} label={t("copyCommand")} copiedLabel={t("copiedCommand")} /></div>
              {data.downloadUrl ? <div className="grid gap-2"><a href={data.downloadUrl} rel="nofollow" className="border border-border bg-background px-3 py-1.5 text-foreground">{t("downloadLink")}</a><p className="text-muted">{t("downloadExpires")}</p></div> : <p className="text-muted">{t("downloadUnavailable")}</p>}
              <details className="border border-border"><summary className="cursor-pointer px-3 py-2 font-medium">{t("snapshotsSummary", { count: data.snapshots.length })}</summary><div className="border-t border-border">{data.snapshots.map((snapshot) => <div key={snapshot.sha256} className="grid gap-1 border-b border-border p-2"><div className="font-mono" title={snapshot.sha256}>{truncateMiddle(snapshot.sha256, 22)}</div><div className="font-mono text-muted">{formatBytes(snapshot.compressedSizeBytes ?? snapshot.sizeBytes, locale)} · {formatDate(new Date(snapshot.uploadedAt), locale)}</div></div>)}</div></details>
            </div>
          </div>
        </details>
      </aside>
      <TranscriptViewer sessionId={data.id} initialMessages={data.messages} complete={data.transcriptComplete} />
    </div>
  );
}

function DashboardVaultCliAuthRoute() {
  const t = useTranslations("vault.cliAuth");
  const code = new URLSearchParams(useLocation().search).get("code")?.trim().toUpperCase() ?? "";
  const initialCode = /^[A-Z2-9]{8}$/.test(code) ? code : "";
  return (
    <div data-testid="dashboard-router-cli-auth" className="mx-auto w-full max-w-3xl px-3 py-4">
      <div className="border-b border-border pb-3">
        <p className="text-xs font-medium text-muted">{t("eyebrow")}</p>
        <h1 className="mt-1 text-sm font-medium">{t("title")}</h1>
        <p className="mt-1 max-w-2xl text-muted">{t("description")}</p>
      </div>
      <ApproveForm initialCode={initialCode} />
    </div>
  );
}

function VaultMetadata({ label, value }: { label: string; value: string }) {
  return <div><div className="text-xs text-muted">{label}</div><div className="mt-1 break-words font-mono text-xs">{value}</div></div>;
}

function DashboardTestflightRoute() {
  const t = useTranslations("dashboard.testflight");
  const queryClient = useQueryClient();
  const location = useLocation();
  const { data } = useSuspenseQuery(orpc.dashboard.testflight.status.queryOptions());
  const [banner, setBanner] = useState<string | null>(() => {
    const value = new URLSearchParams(location.search).get("testflight");
    return ["joined", "left", "error", "ineligible", "needs_email", "unavailable"].includes(value ?? "") ? value : null;
  });
  const mutation = useMutation({
    mutationFn: async (action: "join" | "leave") => {
      const body = new FormData();
      body.set("action", action);
      const response = await fetch("/api/testflight", { method: "POST", body });
      if (!response.ok) throw new Error("TestFlight update failed");
      return action;
    },
    onSuccess: async (action) => {
      setBanner(action === "join" ? "joined" : "left");
      await queryClient.invalidateQueries({ queryKey: orpc.dashboard.testflight.status.queryKey() });
    },
    onError: () => setBanner("error"),
  });

  return (
    <div data-testid="dashboard-router-testflight" className="mx-auto w-full max-w-5xl px-3 py-4">
      <div className="mb-4 border-b border-border pb-3">
        <p className="text-xs font-medium text-muted">{t("eyebrow")}</p>
        <h1 className="mt-1 text-sm font-medium">{t("title")}</h1>
        <p className="mt-1 max-w-2xl text-muted">{t("description")}</p>
      </div>
      {banner ? <div className="mb-3 border border-border bg-background p-3 text-sm">{t(`banners.${banner}`)}</div> : null}
      {data.status === "ineligible" ? (
        <section className="border border-border p-3">
          <h2 className="text-sm font-medium">{t("notEligible.title")}</h2>
          <p className="mt-2 max-w-2xl text-muted">{t("notEligible.body")}</p>
          <LocalizedLink href="/pricing" className="mt-3 inline-block border border-border bg-background px-3 py-1.5 text-foreground">{t("actions.viewPricing")}</LocalizedLink>
        </section>
      ) : data.status === "needs_email" ? (
        <section className="border border-border p-3"><h2 className="text-sm font-medium">{t("needsEmail.title")}</h2><p className="mt-2 max-w-2xl text-muted">{t("needsEmail.body")}</p></section>
      ) : data.status === "unavailable" ? (
        <section className="border border-border p-3"><h2 className="text-sm font-medium">{t("unavailable.title")}</h2><p className="mt-2 max-w-2xl text-muted">{t("unavailable.body")}</p></section>
      ) : data.status === "joinable" ? (
        <section className="border border-border p-3">
          <h2 className="text-sm font-medium">{t("join.title")}</h2>
          <p className="mt-2 max-w-2xl text-muted">{t("join.body", { email: data.email ?? "" })}</p>
          <button type="button" disabled={mutation.isPending} onClick={() => mutation.mutate("join")} className="mt-4 border border-foreground bg-foreground px-3 py-1.5 text-background">{t("actions.join")}</button>
        </section>
      ) : (
        <section className="border border-border p-3">
          <h2 className="text-sm font-medium">{t("enrolled.title")}</h2>
          <p className="mt-2 max-w-2xl text-muted">{t("enrolled.body", { email: data.email ?? "" })}</p>
          <div className="mt-4 grid border border-border sm:grid-cols-2">
            <TestflightMetric label={t("details.email")} value={data.email ?? ""} />
            <TestflightMetric label={t("details.status")} value={data.state ?? t("details.enrolled")} />
          </div>
          <p className="mt-3 max-w-2xl text-muted">{t("enrolled.lapseNote")}</p>
          <button type="button" disabled={mutation.isPending} onClick={() => mutation.mutate("leave")} className="mt-4 border border-border bg-background px-3 py-1.5 text-foreground">{t("actions.leave")}</button>
        </section>
      )}
    </div>
  );
}

function DashboardBillingRoute() {
  const t = useTranslations("dashboard.billing");
  const { locale } = rootRoute.useRouteContext();
  const location = useLocation();
  const { data } = useSuspenseQuery(orpc.dashboard.billing.status.queryOptions());
  const banner = new URLSearchParams(location.search).get("billing");
  const personal = data.personal;
  const personalDate = personal.subscription?.currentPeriodEnd
    ? new Intl.DateTimeFormat(locale, { dateStyle: "medium" }).format(new Date(personal.subscription.currentPeriodEnd))
    : t("dates.unknown");

  return (
    <div data-testid="dashboard-router-billing" className="mx-auto w-full max-w-5xl px-3 py-4">
      <div className="mb-4 border-b border-border pb-3">
        <p className="text-xs font-medium text-muted">{t("eyebrow")}</p>
        <h1 className="mt-1 text-sm font-medium">{t("title")}</h1>
        <p className="mt-1 max-w-2xl text-muted">{t("description")}</p>
      </div>
      {banner && ["cancelled", "resumed", "nosub", "error"].includes(banner) ? <div className="mb-3 border border-border bg-background p-3 text-sm">{t(`banners.${banner}`)}</div> : null}
      {personal.planId === "free" && !data.team?.subscription ? (
        <section className="border border-border p-3">
          <h2 className="text-sm font-medium">{t("free.name")}</h2>
          <p className="mt-2 max-w-2xl text-muted">{t("free.body")}</p>
          <LocalizedLink href="/pricing" className="mt-3 inline-block border border-border bg-background px-3 py-1.5 text-foreground">{t("actions.viewPricing")}</LocalizedLink>
        </section>
      ) : personal.isPro && personal.subscription ? (
        <section className="border border-border p-3">
          <h2 className="text-sm font-medium">{t("pro.name")}</h2>
          <p className="mt-2 max-w-2xl text-muted">
            {personal.subscription.cancelAtPeriodEnd ? t("pro.pendingBody", { date: personalDate }) : t("pro.activeBody", { date: personalDate })}
          </p>
          <div className="mt-4 grid border border-border sm:grid-cols-2"><BillingMetric label={personal.subscription.cancelAtPeriodEnd ? t("details.endsOn") : t("details.renewsOn")} value={personalDate} /><BillingMetric label={t("details.price")} value={personal.subscription.priceId ?? t("dates.unknown")} /></div>
          <div className="mt-4 flex flex-wrap gap-2">
            {personal.subscription.cancelAtPeriodEnd ? <form method="post" action="/api/billing/subscription"><input type="hidden" name="action" value="resume" /><button type="submit" className="border border-border bg-foreground px-3 py-1.5 text-background">{t("actions.resume")}</button></form> : <details className="border border-border px-3 py-1.5"><summary className="cursor-pointer">{t("actions.cancelSummary")}</summary><form method="post" action="/api/billing/subscription" className="mt-3"><input type="hidden" name="action" value="cancel" /><label className="flex items-start gap-2 text-muted"><input required type="checkbox" name="confirm" value="yes" /><span>{t("cancel.checkbox")}</span></label><button type="submit" className="mt-3 border border-border px-3 py-1.5">{t("actions.confirmCancel")}</button></form></details>}
            {personal.billingManagement === "stripe" ? <BillingPortalLink href="/api/billing/portal">{t("actions.manageBilling")}</BillingPortalLink> : null}
          </div>
        </section>
      ) : personal.hasPaidManualGrant ? (
        <section className="border border-border p-3"><h2 className="text-sm font-medium">{t("pro.name")}</h2><p className="mt-2 max-w-2xl text-muted">{t("pro.grantedBody")}</p></section>
      ) : (
        <section className="border border-border p-3"><h2 className="text-sm font-medium">{t("free.name")}</h2><p className="mt-2 max-w-2xl text-muted">{t("free.body")}</p><LocalizedLink href="/pricing" className="mt-3 inline-block border border-border bg-background px-3 py-1.5 text-foreground">{t("actions.viewPricing")}</LocalizedLink></section>
      )}
      {data.team?.subscription ? <section className="mt-3 border border-border p-3"><h2 className="text-sm font-medium">{t("team.name")}</h2><p className="mt-2 max-w-2xl text-muted">{t("team.activeBody", { date: data.team.subscription.currentPeriodEnd ? new Intl.DateTimeFormat(locale, { dateStyle: "medium" }).format(new Date(data.team.subscription.currentPeriodEnd)) : t("dates.unknown"), team: data.team.name })}</p>{data.team.hasCustomer ? <BillingPortalLink href="/api/billing/portal?scope=team">{t("actions.manageBilling")}</BillingPortalLink> : null}</section> : null}
    </div>
  );
}

function DashboardCoderouterRoute() {
  const t = useTranslations("dashboard.coderouter");
  const location = useLocation();
  const team = new URLSearchParams(location.search).get("team") ?? undefined;
  const { data } = useSuspenseQuery(orpc.dashboard.coderouter.overview.queryOptions({ input: { team } }));
  if (data.kind !== "authorized" || !data.team) {
    return <div data-testid="dashboard-router-coderouter" className="mx-auto w-full max-w-5xl px-3 py-4"><div className="border border-border p-3"><h1 className="text-sm font-medium">{t("title")}</h1><p className="mt-2 text-muted">{t("description")}</p></div></div>;
  }
  const shared: SharedAccountsState = data.sharedState === "ok"
    ? { kind: "ok", accounts: data.shared as unknown as readonly SubrouterAccount[] }
    : { kind: data.sharedState } as SharedAccountsState;
  const claude: ClaudeAccountsState = { kind: "ok", accounts: data.claude as unknown as readonly ClaudeAccountDescription[] };
  const native: NativeAccountsState = { kind: "ok", accounts: data.native as unknown as readonly CodeRouterAccountSummary[] };
  return (
    <div data-testid="dashboard-router-coderouter" className="mx-auto w-full max-w-5xl px-3 py-4">
      <div className="mb-4 border-b border-border pb-3"><h1 className="text-sm font-medium">{t("title")}</h1><p className="mt-1 max-w-2xl text-muted">{t("description")}</p><p className="mt-2 text-xs text-muted">{data.team.name}</p></div>
      <CoderouterAccountsSection teamId={data.team.id} canManage={data.team.manageAccounts} claude={claude} native={native} shared={shared} />
    </div>
  );
}

function BillingMetric({ label, value }: { label: string; value: string }) {
  return <div className="border-b border-border p-3 sm:border-b-0 sm:border-r"><p className="text-xs text-muted">{label}</p><p className="mt-2 font-mono text-xs tabular-nums">{value}</p></div>;
}

function BillingPortalLink({ href, children }: { href: string; children: React.ReactNode }) {
  // The portal endpoint creates a session and must perform a document navigation.
  return <a href={href} className="inline-block border border-border bg-background px-3 py-1.5 text-foreground">{children}</a>;
}

function TestflightMetric({ label, value }: { label: string; value: string }) {
  return <div className="border-b border-border p-3 sm:border-b-0 sm:border-r"><p className="text-xs text-muted">{label}</p><p className="mt-2 font-mono text-xs tabular-nums">{value}</p></div>;
}

function DeviceFact({ label, value }: { label: string; value: string }) {
  return <div><dt className="text-muted">{label}</dt><dd className="mt-1 break-words text-foreground">{value}</dd></div>;
}

function DashboardInitialContent() {
  return rootRoute.useRouteContext().initialContent;
}

/**
 * The payment return page and instant navigation fixture remain server-owned
 * Next entries. This bridge preserves their full-document behavior while all
 * authenticated dashboard product routes use native Router components.
 */
function DashboardLegacyRouteBridge() {
  const location = useLocation();
  const currentHref = `${location.pathname}${location.search}${location.hash}`;
  const firstHref = useRef(currentHref);

  useEffect(() => {
    if (currentHref !== firstHref.current) {
      window.location.assign(window.location.href);
    }
  }, [currentHref]);

  return <DashboardInitialContent />;
}

function DashboardRouterNotFound() {
  return rootRoute.useRouteContext().initialContent;
}

function getBrowserHistory(basepath: string, initialRoute: string) {
  if (typeof window === "undefined") {
    const suffix = initialRoute === "/dashboard"
      ? "/"
      : initialRoute.replace(/^\/dashboard(?=\/)/, "");
    return createMemoryHistory({ initialEntries: [`${basepath}${suffix}`] });
  }
  return undefined;
}

function createDashboardRouter(
  basepath: string,
  initialRoute: string,
  context: DashboardRouterContext,
) {
  const router = createRouter({
    routeTree,
    basepath,
    context,
    defaultPreload: "intent",
    defaultPendingMinMs: 100,
    history: getBrowserHistory(basepath, initialRoute),
  });

  return router;
}

export function DashboardRouterProvider({
  locale,
  initialRoute,
  vaultEnabled,
  account,
  children,
}: {
  locale: string;
  initialRoute: string;
  vaultEnabled: boolean;
  account: React.ReactNode;
  children: React.ReactNode;
}) {
  const [queryClient] = useState(() => new QueryClient());
  const basepath = `/${locale}/dashboard`;
  const [router] = useState(() =>
    createDashboardRouter(basepath, initialRoute, {
      queryClient,
      vaultEnabled,
      account,
      initialContent: children,
      locale,
    }),
  );

  return (
    <QueryClientProvider client={queryClient}>
      <RouterProvider router={router} />
    </QueryClientProvider>
  );
}

export { routeTree };
