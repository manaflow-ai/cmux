import { afterEach, describe, expect, mock, test } from "bun:test";
import { isRedirect } from "@tanstack/react-router";
import { createTranslator, type AbstractIntlMessages } from "use-intl/core";
import { loadMessages } from "../i18n/messages";
import { createScreenQueryClient, renderDashboardScreen } from "./helpers/dashboard-spa-render";
import { fakeDashboardRpcFetch, refuse } from "./helpers/fake-dashboard-rpc";

const catalogs = { en: await loadMessages("en"), ja: await loadMessages("ja") };
let locale: keyof typeof catalogs = "en";

// Screens use the client `useTranslations`; back it with the real ICU
// translator over the selected catalog.
mock.module("next-intl", () => ({
  NextIntlClientProvider: ({ children }: { children: React.ReactNode }) => children,
  useLocale: () => locale,
  useNow: () => new Date("2026-09-07T12:00:00.000Z"),
  useFormatter: () => ({
    dateTime: (date: Date) => date.toISOString().slice(0, 10),
    relativeTime: () => "2 hours ago",
  }),
  useTranslations: (namespace?: string) =>
    createTranslator({
      locale,
      messages: catalogs[locale] as AbstractIntlMessages,
      namespace: namespace as never,
      timeZone: "UTC",
    }),
}));

const { coderouterOverviewQuery } = await import("../dashboard-app/queries/coderouter");
const { cloudDevicesQuery } = await import("../dashboard-app/queries/cloud");
const { CoderouterScreen } = await import("../dashboard-app/screens/coderouter/coderouter-screen");
const { CloudScreen } = await import("../dashboard-app/screens/cloud/cloud-screen");
const { coderouterRoutes } = await import("../dashboard-app/routes/coderouter");
type Overview = import("../dashboard-app/lib/coderouter-types").DashboardCoderouterResponse;

const originalFetch = globalThis.fetch;
afterEach(() => {
  locale = "en";
  globalThis.fetch = originalFetch;
});

function overview(overrides: Partial<Overview> = {}): Overview {
  return {
    selectedTeam: {
      id: "team-1",
      name: "Team One",
      use: true,
      manageAccounts: true,
      manageApiKeys: false,
      personal: false,
    },
    transferTeams: [],
    viewerUserId: "user-1",
    metrics: {
      kind: "ready",
      periodDays: 30,
      generatedAt: "2026-08-08T12:00:00.000Z",
      rateCardVersion: "2026-08-08",
      totals: {
        inputTokens: 1_000,
        cachedInputTokens: 200,
        outputTokens: 300,
        totalTokens: 1_300,
        apiEquivalentUsd: 4.25,
        pricedTokens: 1_300,
        unpricedTokens: 0,
      },
      daily: [{ day: "2026-08-08", totalTokens: 1_300, apiEquivalentUsd: 4.25 }],
    },
    machineUsage: {
      kind: "ready",
      periodDays: 30,
      machines: [{
        vmId: "0f4b1c2e-1111-4222-8333-444455556666",
        providerVmId: null,
        displayName: "builder-01",
        totals: { inputTokens: 900, cachedInputTokens: 100, outputTokens: 100, totalTokens: 1_000, apiEquivalentUsd: 2.5 },
      }],
    },
    claude: { kind: "ok", accounts: [] },
    native: { kind: "ok", accounts: [] },
    shared: { kind: "ok", accounts: [{ id: "shared-1", kind: "codex", label: "shared codex", health: { ok: true } }] },
    ...overrides,
  };
}

async function renderCoderouter(data: Overview, url = "/dashboard/coderouter?team=team-1") {
  const queryClient = createScreenQueryClient();
  const team = new URL(url, "https://cmux.test").searchParams.get("team") ?? undefined;
  queryClient.setQueryData(coderouterOverviewQuery(team).queryKey, data);
  return renderDashboardScreen({ url, queryClient, render: () => <CoderouterScreen /> });
}

describe("coderouter screen", () => {
  test("renders the header, team metrics, accounts, and owned machines", async () => {
    const html = await renderCoderouter(overview());
    expect(html).toContain("Coderouter routes llm requests");
    expect(html).toContain("30-day usage");
    expect(html).toContain("Team aggregate for Team One");
    expect(html).toContain("Last 30 days");
    expect(html).toContain("1.3K");
    expect(html).toContain("$4.25");
    expect(html).toContain("rate card 2026-08-08");
    expect(html).not.toContain("without a list price");
    expect(html).toContain("No prompts, outputs, account labels, or member identities");
    expect(html).toContain("shared codex");
    expect(html).toContain("Per-machine coderouter usage for Team One over the last 30 days.");
    expect(html).toContain("builder-01");
    expect(html).toContain("$2.50");
  });

  test("reads the overview for the Stack-selected team when the URL has no team", async () => {
    const html = await renderCoderouter(overview(), "/dashboard/coderouter");
    expect(html).toContain("Team aggregate for Team One");
  });

  test("explains unpriced tokens and unavailable sections", async () => {
    const ready = overview().metrics;
    if (ready.kind !== "ready") throw new Error("fixture");
    const html = await renderCoderouter(overview({
      metrics: { ...ready, totals: { ...ready.totals, unpricedTokens: 650, pricedTokens: 650 } },
      machineUsage: { kind: "unavailable", periodDays: 30 },
    }));
    expect(html).toContain("50% of these tokens came from models without a list price");
    expect(html).toContain("Machine usage is temporarily unavailable.");

    const unavailable = await renderCoderouter(overview({ metrics: { kind: "unavailable" } }));
    expect(unavailable).toContain("Team usage is temporarily unavailable.");
  });

  test("renders the metrics copy from the Japanese catalog", async () => {
    locale = "ja";
    const html = await renderCoderouter(overview());
    expect(html).toContain("30日間の使用状況");
    expect(html).toContain("Team One のチーム集計");
    expect(html).toContain("過去30日間");
    expect(html).toContain("レート表 2026-08-08");
  });

  test("sends a viewer with no coderouter team to the dashboard home", async () => {
    globalThis.fetch = fakeDashboardRpcFetch({
      "coderouter.overview": () => {
        throw refuse(409, "no_teams");
      },
    });
    const route = coderouterRoutes[0];
    const loader = route.options.loader as (input: unknown) => Promise<unknown>;
    const thrown = await loader({
      context: { queryClient: createScreenQueryClient(), locale: "en" },
      deps: { team: undefined },
    }).then(() => null, (error: unknown) => error);
    expect(isRedirect(thrown)).toBe(true);
    expect((thrown as { options: { to: string } }).options.to).toBe("/dashboard");
  });
});

describe("cloud screen", () => {
  const device = {
    id: "grant-1",
    deviceId: "device-1234567890",
    name: "Studio Mac",
    reportedName: "Studio Mac",
    displayName: null,
    modelIdentifier: "Mac15,3",
    osVersion: "26.1",
    architecture: "arm64",
    cmuxVersion: "0.70.0",
    cmuxBuild: "123",
    cmuxChannel: "nightly",
    createdAt: 1_780_000_000_000,
    lastControlPlaneAt: 1_780_000_100_000,
    tunnelPurposes: ["browser", "terminal"] as ("browser" | "terminal")[],
  };

  async function renderCloud(devices: readonly (typeof device)[]) {
    const queryClient = createScreenQueryClient();
    queryClient.setQueryData(cloudDevicesQuery.queryKey, { devices: [...devices] });
    return renderDashboardScreen({ url: "/dashboard/cloud", queryClient, render: () => <CloudScreen /> });
  }

  test("lists each Mac with its build, access, and actions", async () => {
    const html = await renderCloud([device]);
    expect(html).toContain("Cloud Mac access");
    expect(html).toContain("Studio Mac");
    expect(html).toContain("Mac15,3 · macOS 26.1 · arm64");
    expect(html).toContain("nightly 0.70.0 (123)");
    expect(html).toContain("browser VPN, terminal");
    expect(html).toContain("…34567890");
    expect(html).toContain(">rename<");
    expect(html).toContain(">revoke<");
  });

  test("explains an empty list", async () => {
    const html = await renderCloud([]);
    expect(html).toContain("No Mac has enrolled for Cloud VM access.");
  });
});
