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
} from "@tanstack/react-router";
import { QueryClient, QueryClientProvider, useSuspenseQuery } from "@tanstack/react-query";
import { AccountSettings } from "@stackframe/stack";
import { useTranslations } from "next-intl";
import { useEffect, useRef, useState } from "react";
import { z } from "zod";

import { orpc } from "@/orpc/query";
import { DashboardShell } from "./dashboard-shell";
import { CloudDeviceActions } from "./cloud/device-actions";

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
  component: routeSlot,
});
const testflightRoute = createRoute({
  getParentRoute: () => rootRoute,
  path: "/testflight",
  validateSearch: z.object({ testflight: z.string().optional() }),
  component: routeSlot,
});
const billingRoute = createRoute({
  getParentRoute: () => rootRoute,
  path: "/billing",
  validateSearch: z.object({ billing: z.string().optional(), interval: z.string().optional() }),
  component: routeSlot,
});
const teamRoute = createRoute({ getParentRoute: () => rootRoute, path: "/team", component: DashboardTeamRoute });
const vaultRoute = createRoute({ getParentRoute: () => rootRoute, path: "/vault", component: routeSlot });
const vaultSessionsRoute = createRoute({
  getParentRoute: () => rootRoute,
  path: "/vault/sessions",
  validateSearch: z.object({ q: z.string().optional(), cursor: z.string().optional(), before: z.string().optional() }),
  component: routeSlot,
});
const vaultSessionRoute = createRoute({ getParentRoute: () => rootRoute, path: "/vault/sessions/$id", component: routeSlot });
const vaultCliAuthRoute = createRoute({
  getParentRoute: () => rootRoute,
  path: "/vault/cli-auth",
  validateSearch: z.object({ code: z.string().optional() }),
  component: routeSlot,
});
const navigationFixtureRoute = createRoute({ getParentRoute: () => rootRoute, path: "/navigation-fixture", component: routeSlot });
const legacySubrouterRoute = createRoute({
  getParentRoute: () => rootRoute,
  path: "/subrouter",
  validateSearch: z.object({ team: z.string().optional() }),
  component: routeSlot,
});
const legacyAiAccountsRoute = createRoute({
  getParentRoute: () => rootRoute,
  path: "/ai-accounts",
  validateSearch: z.object({ team: z.string().optional() }),
  component: routeSlot,
});

const routeTree = rootRoute.addChildren([
  indexRoute,
  cloudRoute,
  coderouterRoute,
  testflightRoute,
  billingRoute,
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

function DeviceFact({ label, value }: { label: string; value: string }) {
  return <div><dt className="text-muted">{label}</dt><dd className="mt-1 break-words text-foreground">{value}</dd></div>;
}

function DashboardInitialContent() {
  return rootRoute.useRouteContext().initialContent;
}

/**
 * Keeps the existing Next page implementations as the server authority while
 * the dashboard route tree is migrated one screen at a time. A client-side
 * navigation is still owned by TanStack Router; until its route has a native
 * client component, the bridge asks Next for the matching server page.
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
