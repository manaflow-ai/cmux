import { beforeEach, describe, expect, mock, test } from "bun:test";
import { renderToStaticMarkup } from "react-dom/server";
import enMessages from "../messages/en.json";

const authorizationFailure = new Error("Stack authorization deadline exceeded");
const pendingAuthorization = new Promise<never>(() => {});
let authorizationAvailable = false;
let authorizationPending = false;
let authJsonAvailable = true;
let cutoverReady = true;
let hostedControlConfigured = true;
let hostedExchangeCalls = 0;
let selectedTeamId: string | null = "team-1";
let scopedTeamId: string | null = null;
let authorizationCalls = 0;
let authorizedTeams: Array<{
  teamId: string;
  teamName: string;
  use: boolean;
  manageAccounts: boolean;
  personal?: boolean;
}> = [{
  teamId: "team-1",
  teamName: "Team One",
  use: true,
  manageAccounts: true,
}];
const metricsTeamIds: string[] = [];

mock.module("next-intl/server", () => ({
  getTranslations: async (input?: string | { namespace?: string }) =>
    translator(typeof input === "string" ? input : input?.namespace),
  setRequestLocale: () => undefined,
}));

mock.module("next/server", () => ({
  // The usage ledger defers its ClickHouse insert past the response with
  // `after`; the render under test only needs the callback to be accepted.
  after: (task: () => unknown) => {
    void task;
  },
}));

mock.module("next/headers", () => ({
  headers: async () => {
    return new Headers(
      scopedTeamId
        ? {
          cookie: `cmux_coderouter_organization=${
            encodeURIComponent(JSON.stringify(["user-1", scopedTeamId]))
          }`,
        }
        : undefined,
    );
  },
}));

mock.module("next/cache", () => ({
  cacheLife: () => undefined,
}));

mock.module("next/navigation", () => ({
  redirect: (target: string) => {
    throw new Error(`unexpected redirect to ${target}`);
  },
}));

mock.module("@/i18n/navigation", () => ({
  Link: ({
    href,
    children,
    ...props
  }: {
    href: string;
    children: React.ReactNode;
  }) => <a href={href} {...props}>{children}</a>,
  redirect: () => undefined,
  usePathname: () => "/dashboard/coderouter",
  useRouter: () => ({}),
  getPathname: () => "/dashboard/coderouter",
}));

mock.module("../app/lib/stack", () => ({
  isStackConfigured: () => true,
  getStackServerApp: () => ({
    getAuthJson: async () => {
      if (!authJsonAvailable) throw new Error("Stack refresh unavailable");
      return { accessToken: "test-access-token" };
    },
  }),
}));

mock.module(
  "../app/[locale]/dashboard/components/dashboard-page-headers",
  () => ({
    CoderouterPageHeader: () => (
      <h1 data-testid="coderouter-page-header">coderouter</h1>
    ),
  }),
);

class TestSubrouterAuthorizationUnavailableError extends Error {}

mock.module("../services/vms/auth", () => ({
  withSubrouterAuthorizationDeadline: async (
    operation: (signal: AbortSignal) => Promise<unknown>,
  ) => {
    if (authorizationPending) return pendingAuthorization;
    if (!authorizationAvailable) throw authorizationFailure;
    return await operation(new AbortController().signal);
  },
  verifySubrouterRequest: async () => {
    authorizationCalls += 1;
    return { id: "user-1", selectedTeamId };
  },
  SubrouterAuthorizationUnavailableError:
    TestSubrouterAuthorizationUnavailableError,
  isSubrouterAuthorizationError: (error: unknown) =>
    error === authorizationFailure ||
    error instanceof TestSubrouterAuthorizationUnavailableError,
}));

mock.module("../services/subrouter/routeHelpers", () => ({
  authorizedSubrouterTeams: async () => authorizedTeams,
}));

mock.module("../services/subrouter/hostedClient", () => ({
  createHostedSubrouterClient: () => ({
    tenantControlConfigured: hostedControlConfigured,
    exchangeTeam: async () => {
      hostedExchangeCalls += 1;
      return {
        tenantId: "team-1",
        tenantKey: "srt_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
      };
    },
    listAccounts: async () => [],
  }),
}));

mock.module("../services/subrouter/cutover", () => ({
  hostedSubrouterCutoverReadyForTeam: async () => cutoverReady,
}));

mock.module("../services/coderouter/teamMetrics", () => ({
  loadCoderouterTeamMetrics: async (teamId: string) => {
    metricsTeamIds.push(teamId);
    return {
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
      daily: [{
        day: "2026-08-08",
        totalTokens: 1_300,
        apiEquivalentUsd: 4.25,
      }],
    };
  },
}));

mock.module("../db/client", () => ({
  cloudDb: () => ({}),
}));

const machineMetricsCalls: Array<[string, string]> = [];
let machineMetricsKind: "ready" | "unavailable" = "ready";

mock.module("../services/coderouter/vmMetrics", () => ({
  loadCoderouterTeamMachineMetrics: async (teamId: string, surface: string) => {
    machineMetricsCalls.push([teamId, surface]);
    return machineMetricsKind === "ready"
      ? {
        kind: "ready",
        periodDays: 30,
        generatedAt: "2026-08-08T12:00:00.000Z",
        rateCardVersion: "2026-08-08",
        machines: [{
          vmId: "0f4b1c2e-1111-4222-8333-444455556666",
          totals: {
            inputTokens: 900,
            cachedInputTokens: 100,
            outputTokens: 100,
            totalTokens: 1_000,
            apiEquivalentUsd: 2.5,
            pricedTokens: 1_000,
            unpricedTokens: 0,
          },
        }, {
          vmId: "not-owned-by-this-team",
          totals: {
            inputTokens: 1,
            cachedInputTokens: 0,
            outputTokens: 1,
            totalTokens: 2,
            apiEquivalentUsd: 0.01,
            pricedTokens: 2,
            unpricedTokens: 0,
          },
        }],
      }
      : { kind: "unavailable" };
  },
}));

mock.module("../services/coderouter/teamMachines", () => ({
  listTeamMachines: async () => [{
    vmId: "0f4b1c2e-1111-4222-8333-444455556666",
    displayName: "builder-01",
    destroyed: false,
    createdAt: "2026-08-01T00:00:00.000Z",
  }],
  findTeamMachine: async () => null,
  normalizeVmId: (value: string) => value,
}));

mock.module("../app/[locale]/dashboard/components/ai-account-forms", () => ({
  AddAiAccountForms: () => null,
  DeleteAiAccountButton: () => null,
}));

mock.module("../services/coderouter/claudeUpstream", () => ({
  listClaudeAccounts: async () => [],
}));

mock.module("../app/[locale]/dashboard/components/claude-upstream-forms", () => ({
  ClaudeUpstreamSection: () => null,
}));

const { default: CoderouterOverviewPage, CoderouterOverviewContent } = await import(
  "../app/[locale]/dashboard/coderouter/page"
);

describe("coderouter dashboard", () => {
  beforeEach(() => {
    authorizationAvailable = false;
    authorizationPending = false;
    authJsonAvailable = true;
    cutoverReady = true;
    hostedControlConfigured = true;
    hostedExchangeCalls = 0;
    metricsTeamIds.length = 0;
    machineMetricsCalls.length = 0;
    machineMetricsKind = "ready";
    selectedTeamId = "team-1";
    scopedTeamId = null;
    authorizationCalls = 0;
    authorizedTeams = [{
      teamId: "team-1",
      teamName: "Team One",
      use: true,
      manageAccounts: true,
    }];
  });

  test("keeps the page header hidden until the private page content is ready", () => {
    authorizationPending = true;

    const html = renderToStaticMarkup(
      <CoderouterOverviewPage
        params={Promise.resolve({ locale: "en" })}
        searchParams={Promise.resolve({})}
      />,
    );

    expect(html).not.toContain('data-testid="coderouter-page-header"');
  });

  test("renders recovery UI when Stack authorization is unavailable", async () => {
    const page = await CoderouterOverviewContent({
      locale: "en",
    });
    const html = renderToStaticMarkup(page);

    expect(html).toContain("Accounts could not load");
    expect(html).toContain('data-testid="coderouter-page-header"');
    expect(html).toContain(
      "The account service could not be reached. Try again shortly.",
    );
    expect(html).not.toContain("unexpected redirect");
  });

  test("keeps a legacy-mapped team off hosted accounts until migration finishes", async () => {
    authorizationAvailable = true;
    cutoverReady = false;

    const page = await CoderouterOverviewContent({
      locale: "en",
    });
    const html = renderToStaticMarkup(page);

    expect(hostedExchangeCalls).toBe(0);
    expect(html).toContain("Accounts temporarily unavailable");
    expect(html).toContain(
      "Shared accounts are temporarily unavailable. Try again shortly.",
    );
  });

  test("renders recovery UI when the bounded Stack session refresh fails", async () => {
    authorizationAvailable = true;
    authJsonAvailable = false;

    const page = await CoderouterOverviewContent({
      locale: "en",
    });
    const html = renderToStaticMarkup(page);

    expect(html).toContain("Accounts could not load");
    expect(html).toContain(
      "The account service could not be reached. Try again shortly.",
    );
    expect(hostedExchangeCalls).toBe(0);
  });

  test("renders setup guidance when hosted tenant control is not configured", async () => {
    authorizationAvailable = true;
    hostedControlConfigured = false;

    const page = await CoderouterOverviewContent({
      locale: "en",
    });
    const html = renderToStaticMarkup(page);

    expect(html).toContain("AI account management isn&#x27;t available yet");
    expect(hostedExchangeCalls).toBe(0);
  });

  test("renders aggregate metrics only for the authorized selected team", async () => {
    authorizationAvailable = true;

    const page = await CoderouterOverviewContent({
      locale: "en",
      team: "team-1",
    });
    const html = renderToStaticMarkup(page);

    expect(metricsTeamIds).toEqual(["team-1"]);
    expect(html).toContain("30-day usage");
    expect(html).toContain("1.3K");
    expect(html).toContain("$4.25");
    expect(html).toContain("No prompts, outputs, account labels, or member identities");
    expect(html).not.toContain("stack-user");
  });

  test("renders the Machines card for owned machines only", async () => {
    authorizationAvailable = true;

    const page = await CoderouterOverviewContent({
      locale: "en",
      team: "team-1",
    });
    const html = renderToStaticMarkup(page);

    expect(machineMetricsCalls).toEqual([["team-1", "dashboard"]]);
    expect(html).toContain("Machines");
    expect(html).toContain("Per-machine coderouter usage for Team One over the last 30 days.");
    expect(html).toContain("builder-01");
    expect(html).toContain("0f4b1c2e-1111-4222-8333-444455556666");
    expect(html).toContain("$2.50");
    expect(html).not.toContain("not-owned-by-this-team");
  });

  test("renders the Machines card fallback when per-machine metrics are unavailable", async () => {
    authorizationAvailable = true;
    machineMetricsKind = "unavailable";

    const page = await CoderouterOverviewContent({
      locale: "en",
      team: "team-1",
    });
    const html = renderToStaticMarkup(page);

    expect(html).toContain("Machine usage is temporarily unavailable.");
    expect(html).not.toContain("builder-01");
  });

  test("uses the authenticated selected team when the URL has no team scope", async () => {
    authorizationAvailable = true;
    selectedTeamId = "team-2";
    authorizedTeams = [
      {
        teamId: "team-1",
        teamName: "Team One",
        use: true,
        manageAccounts: true,
      },
      {
        teamId: "team-2",
        teamName: "Team Two",
        use: true,
        manageAccounts: true,
      },
    ];

    await CoderouterOverviewContent({
      locale: "en",
    });

    expect(metricsTeamIds).toEqual(["team-2"]);
  });

  test("uses the persisted CodeRouter scope before the Stack default", async () => {
    authorizationAvailable = true;
    selectedTeamId = "team-1";
    scopedTeamId = "team-2";
    authorizedTeams = [
      {
        teamId: "team-1",
        teamName: "Team One",
        use: true,
        manageAccounts: true,
      },
      {
        teamId: "team-2",
        teamName: "Team Two",
        use: true,
        manageAccounts: true,
      },
    ];

    await CoderouterOverviewContent({
      locale: "en",
    });

    expect(metricsTeamIds).toEqual(["team-2"]);
  });

  test("normalizes a null Stack selection to the personal organization", async () => {
    authorizationAvailable = true;
    selectedTeamId = null;
    authorizedTeams = [
      {
        teamId: "team-1",
        teamName: "Team One",
        use: true,
        manageAccounts: true,
        personal: false,
      },
      {
        teamId: "user-1",
        teamName: "Personal",
        use: true,
        manageAccounts: true,
        personal: true,
      },
    ];

    await CoderouterOverviewContent({
      locale: "en",
    });

    expect(metricsTeamIds).toEqual(["user-1"]);
  });

  test("uses personal when the Stack-selected team is no longer authorized", async () => {
    authorizationAvailable = true;
    selectedTeamId = "stale-team";
    authorizedTeams = [
      {
        teamId: "team-1",
        teamName: "Team One",
        use: true,
        manageAccounts: true,
        personal: false,
      },
      {
        teamId: "user-1",
        teamName: "Personal",
        use: true,
        manageAccounts: true,
        personal: true,
      },
    ];

    await CoderouterOverviewContent({
      locale: "en",
    });

    expect(metricsTeamIds).toEqual(["user-1"]);
  });

  test("rechecks live team grants before rendering the page", async () => {
    authorizationAvailable = true;

    await CoderouterOverviewContent({
      locale: "en",
      team: "team-1",
    });
    expect(authorizationCalls).toBe(1);

    authorizedTeams = [];
    await expect(
      CoderouterOverviewContent({ locale: "en", team: "team-1" }),
    ).rejects.toThrow("unexpected redirect to /dashboard");

    expect(authorizationCalls).toBe(2);
    expect(metricsTeamIds).toEqual(["team-1"]);
  });
});

function translator(namespace?: string) {
  const root = namespace ? valueAtPath(enMessages, namespace) : enMessages;
  const t = (key: string, values?: Record<string, unknown>) =>
    interpolate(String(valueAtPath(root, key)), values);
  t.raw = (key: string) => valueAtPath(root, key);
  t.rich = (key: string, values?: Record<string, unknown>) =>
    interpolate(String(valueAtPath(root, key)), values);
  return t;
}

function valueAtPath(root: unknown, path: string): unknown {
  return path.split(".").reduce<unknown>((value, part) => {
    if (value && typeof value === "object" && part in value) {
      return (value as Record<string, unknown>)[part];
    }
    return path;
  }, root);
}

function interpolate(
  message: string,
  values?: Record<string, unknown>,
): string {
  if (!values) return message;
  return Object.entries(values).reduce(
    (result, [key, value]) => result.replaceAll(`{${key}}`, String(value)),
    message,
  );
}
