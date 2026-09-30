import { afterAll, beforeEach, describe, expect, mock, test } from "bun:test";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { createMemoryHistory, RouterProvider } from "@tanstack/react-router";
import { NextIntlClientProvider } from "next-intl";
import type React from "react";
import { renderToStaticMarkup } from "react-dom/server";
import { loadMessages } from "../i18n/messages";
import { fakeDashboardRpcFetch, refuse } from "./helpers/fake-dashboard-rpc";

// Builds the real dashboard route tree with memory history and asserts the
// public URL contract: typed routes, flat string search, not-found, and the
// session gate. Only leaf UI that needs a browser SDK is stubbed.

mock.module("@hexclave/next", () => ({
  useStackApp: () => ({ signOut: async () => undefined }),
  useUser: () => null,
  UserAvatar: () => <span data-testid="avatar" />,
  StackTheme: ({ children }: React.PropsWithChildren) => children,
}));
mock.module("@/app/[locale]/theme", () => ({
  useThemeToggle: () => ({ resolvedTheme: "dark", toggle: () => undefined }),
}));

type SessionReply = { status: number; vaultEnabled?: boolean };
let sessionReply: SessionReply = { status: 200 };
const requested: string[] = [];
const originalFetch = globalThis.fetch;

const serveRpc = fakeDashboardRpcFetch({
  "account.session": () => {
    if (sessionReply.status !== 200) throw refuse(sessionReply.status, "x");
    return {
      user: {
        id: "user-1",
        displayName: "User One",
        primaryEmail: "user@example.com",
        primaryEmailVerified: true,
        profileImageUrl: null,
        selectedTeamId: null,
      },
      flags: { vaultEnabled: sessionReply.vaultEnabled ?? true },
    };
  },
  "vault.summary": () => ({ sessionCount: 0, rawBytes: 0, compressedBytes: 0, lastUploadedAt: null, agents: [] }),
  "cloud.devices": () => {
    throw refuse(503, "service_unavailable");
  },
});

/** Records each dashboard procedure the SPA calls, e.g. `vault.summary`. */
globalThis.fetch = (async (input: RequestInfo | URL, init?: RequestInit) => {
  const request = input instanceof Request && init === undefined ? input : new Request(input, init);
  requested.push(new URL(request.url).pathname.replace("/api/dashboard/rpc/", "").replaceAll("/", "."));
  return serveRpc(request);
}) as typeof fetch;

afterAll(() => {
  globalThis.fetch = originalFetch;
});

const { createDashboardRouter } = await import("../dashboard-app/router");

async function loadRouter(url: string, locale = "en") {
  const queryClient = new QueryClient({ defaultOptions: { queries: { retry: false } } });
  const pathname = url.split(/[?#]/)[0]!;
  const router = createDashboardRouter({
    queryClient,
    locale,
    pathname,
    history: createMemoryHistory({ initialEntries: [url] }),
  });
  router.update({
    ...router.options,
    isServer: false,
    scrollRestoration: false,
    origin: "http://localhost",
  });
  await router.load();
  return { router, queryClient };
}

async function render(url: string, locale = "en") {
  const { router, queryClient } = await loadRouter(url, locale);
  // Error boundaries do not run in a static render; in server mode the
  // router renders a failed match's errorComponent directly instead.
  router.update({ ...router.options, isServer: true });
  const messages = await loadMessages(locale as "en");
  const html = renderToStaticMarkup(
    <QueryClientProvider client={queryClient}>
      <NextIntlClientProvider locale={locale} messages={messages} timeZone="UTC">
        <RouterProvider router={router} />
      </NextIntlClientProvider>
    </QueryClientProvider>,
  );
  return { router, html };
}

function leafRouteId(router: Awaited<ReturnType<typeof loadRouter>>["router"]): string {
  return router.state.matches.at(-1)?.routeId ?? "";
}

beforeEach(() => {
  sessionReply = { status: 200 };
  requested.length = 0;
});

describe("dashboard router", () => {
  test.each([
    ["/dashboard", "/shell/dashboard"],
    ["/dashboard/billing", "/shell/dashboard/billing"],
    ["/dashboard/testflight", "/shell/dashboard/testflight"],
    ["/dashboard/coderouter", "/shell/dashboard/coderouter"],
    ["/dashboard/cloud", "/shell/dashboard/cloud"],
    ["/dashboard/mobile-devices", "/shell/dashboard/mobile-devices"],
    ["/dashboard/settings", "/shell/dashboard/settings/"],
    ["/dashboard/settings/api-keys", "/shell/dashboard/settings/api-keys"],
    ["/dashboard/teams", "/shell/dashboard/teams"],
    ["/dashboard/teams/new", "/shell/dashboard/teams/new"],
    ["/dashboard/teams/abc/members", "/shell/dashboard/teams/$teamId/members"],
    ["/dashboard/team/accept", "/shell/dashboard/team/accept"],
    ["/dashboard/vault", "/shell/dashboard/vault"],
    ["/dashboard/vault/sessions", "/shell/dashboard/vault/sessions"],
    ["/dashboard/vault/cli-auth", "/shell/dashboard/vault/cli-auth"],
  ])("resolves %s to %s", async (url, routeId) => {
    const { router } = await loadRouter(url);
    expect(leafRouteId(router)).toBe(routeId);
    expect(router.state.matches.some((match) => match._notFound)).toBe(false);
  });

  test("the locale prefix is the basepath, so route paths stay public", async () => {
    const { router } = await loadRouter("/ja/dashboard/settings", "ja");
    expect(router.options.basepath).toBe("/ja");
    expect(router.state.location.pathname).toBe("/dashboard/settings");
    expect(leafRouteId(router)).toBe("/shell/dashboard/settings/");
    expect(router.buildLocation({ to: "/dashboard/billing" }).href).toBe("/ja/dashboard/billing");
  });

  test("search params stay flat strings", async () => {
    const { router } = await loadRouter("/dashboard/vault/sessions?q=123&team=007");
    const match = router.state.matches.at(-1)!;
    expect(match.search).toMatchObject({ q: "123", team: "007" });
    expect(router.state.location.searchStr).toBe("?q=123&team=007");
    expect(router.buildLocation({ to: "/dashboard/coderouter", search: { team: "42" } }).href)
      .toBe("/dashboard/coderouter?team=42");
  });

  test("an unknown path renders not-found inside the frame", async () => {
    const { router, html } = await render("/dashboard/does-not-exist");
    expect(router.state.matches.find((match) => match.routeId === "/shell")?._notFound).toBe(true);
    expect(html).toContain('data-testid="dashboard-shell"');
    expect(html).toContain("Page not found");
  });

  test.each([
    ["/dashboard/coderouter?team=t1", "en", "coderouter — cmux"],
    ["/ja/dashboard/coderouter", "ja", "coderouter — cmux"],
  ])("%s renders its route title", async (url, locale, title) => {
    const { html } = await render(url, locale);
    // The overview fetch fails in this stub; the title comes from the route, not the data.
    expect(html.match(/<title>([^<]*)<\/title>/g)).toEqual([`<title>${title}</title>`]);
  });

  test.each(["/dashboard", "/dashboard/billing", "/dashboard/does-not-exist"])(
    "%s keeps the layout title",
    async (url) => {
      const { html } = await render(url);
      expect(html).not.toContain("<title>");
    },
  );

  test("renders the home screen inside the shell", async () => {
    const { html } = await render("/dashboard");
    expect(html).toContain('data-testid="dashboard-shell"');
    // The home cards follow the shell navigation; Vault leads when enabled.
    const main = html.slice(html.indexOf("<main"));
    expect(main.indexOf('href="/dashboard/vault"')).toBeGreaterThan(-1);
    expect(main.indexOf('href="/dashboard/vault"')).toBeLessThan(main.indexOf('href="/dashboard/cloud"'));
    expect(main).toContain('href="/dashboard/testflight"');
  });

  test.each(["/dashboard/teams/new", "/dashboard/settings/account"])(
    "%s renders inside the settings hub with its subnav",
    async (url) => {
      const { html } = await render(url);
      expect(html).toContain('data-testid="settings-hub"');
      const hub = html.slice(html.indexOf('data-testid="settings-hub"'));
      expect(hub).toContain('href="/dashboard/billing"');
      expect(hub).toContain('href="/dashboard/teams/new"');
    },
  );

  test("a 401 session renders the sign-in redirect with the exact destination", async () => {
    sessionReply = { status: 401 };
    const { html } = await render("/dashboard/coderouter?team=t1");
    expect(html).not.toContain('data-testid="dashboard-shell"');
    expect(html).toContain("<span hidden");
  });

  test("a 503 session renders auth recovery that returns to the destination", async () => {
    sessionReply = { status: 503 };
    const { html } = await render("/dashboard/billing?billing=error");
    expect(html).toContain('data-testid="dashboard-auth-recovery"');
    expect(html).not.toContain('data-testid="dashboard-shell"');
    expect(decodeURIComponent(decodeURIComponent(html))).toContain("/dashboard/billing?billing=error");
  });

  test("a 503 from page data shows the page's own error, not sign-in recovery", async () => {
    const { html } = await render("/dashboard/cloud");
    expect(html).toContain('data-testid="dashboard-shell"');
    expect(html).toContain('data-testid="section-error"');
    expect(html).toContain("Cloud Mac access");
    expect(html).toContain("Try again");
    expect(html).not.toContain('data-testid="dashboard-auth-recovery"');
  });

  test("vault pages are not found when the release flag is off", async () => {
    sessionReply = { status: 200, vaultEnabled: false };
    for (const url of ["/dashboard/vault", "/dashboard/vault/sessions"]) {
      const { router } = await loadRouter(url);
      expect(router.state.matches.at(-1)?.status).toBe("notFound");
    }
    expect(requested).not.toContain("vault.summary");
    const { html } = await render("/dashboard/vault");
    expect(html).toContain("Page not found");
    expect(html).not.toContain('href="/dashboard/vault"');
    const { router } = await loadRouter("/dashboard/vault/cli-auth");
    expect(router.state.matches.at(-1)?.status).toBe("success");
  });

  test("a malformed vault session id is not found without an API call", async () => {
    const { router } = await loadRouter("/dashboard/vault/sessions/not-a-uuid");
    expect(router.state.matches.at(-1)?.status).toBe("notFound");
    expect(requested.some((path) => path.startsWith("vault.session"))).toBe(false);
  });

  test.each([
    ["/dashboard/ai-accounts?team=t%201", "/dashboard/coderouter?team=t+1"],
    ["/dashboard/subrouter?team=abc", "/dashboard/coderouter?team=abc"],
    ["/dashboard/subrouter", "/dashboard/coderouter"],
    ["/dashboard/iroh", "/dashboard/mobile-devices"],
    ["/dashboard/team#team-abc", "/dashboard/teams/abc"],
    ["/dashboard/team#team-creation", "/dashboard/teams/new"],
    ["/dashboard/team#payments", "/dashboard/billing"],
    ["/dashboard/team#api-keys", "/dashboard/settings/api-keys"],
    ["/dashboard/team", "/dashboard/settings"],
  ])("redirects %s to %s", async (from, to) => {
    const { router } = await loadRouter(from);
    expect(router.state.location.href).toBe(to);
    expect(router.history.length).toBe(1);
  });

  test("redirects keep the locale basepath", async () => {
    const { router } = await loadRouter("/ja/dashboard/iroh", "ja");
    expect(router.history.location.pathname).toBe("/ja/dashboard/mobile-devices");
  });
});
