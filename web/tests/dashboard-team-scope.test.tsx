import { beforeEach, describe, expect, mock, spyOn, test } from "bun:test";
import { renderToStaticMarkup } from "react-dom/server";

type Catalog = {
  selectedTeamId: string | null;
  teams: Array<{
    id: string;
    name: string;
    personal: boolean;
    permissions: { use: boolean; manageAccounts: boolean };
  }>;
};

let catalog: Catalog | undefined;
let pending = false;
let searchTeam: string | null = null;
const queryData = new Map<string, unknown>();
const routerReplace = mock(() => undefined);
const routerRefresh = mock(() => undefined);

function queryKey(value: readonly unknown[]): string {
  return JSON.stringify(value);
}

const queryClient = {
  getQueryData: (key: readonly unknown[]) => queryData.get(queryKey(key)),
  setQueryData: (key: readonly unknown[], update: unknown) => {
    const keyString = queryKey(key);
    const current = queryData.get(keyString);
    queryData.set(keyString, typeof update === "function" ? update(current) : update);
  },
};

mock.module("@tanstack/react-query", () => ({
  useQuery: () => ({ data: catalog, isPending: pending }),
  useQueryClient: () => queryClient,
}));

mock.module("next/navigation", () => ({
  useSearchParams: () => ({
    get: (name: string) => (name === "team" ? searchTeam : null),
    has: (name: string) => name === "team" && searchTeam !== null,
    toString: () => searchTeam ? `team=${encodeURIComponent(searchTeam)}` : "",
  }),
}));

mock.module("@/i18n/navigation", () => ({
  usePathname: () => "/dashboard/coderouter",
  useRouter: () => ({ replace: routerReplace, refresh: routerRefresh }),
}));

const { useDashboardTeamScope, parseTeamCatalog, selectedTeam, permittedTeams } = await import(
  "../app/[locale]/dashboard/dashboard-team-scope"
);

function Probe({ userId }: { userId: string | null }) {
  const scope = useDashboardTeamScope(userId);
  return (
    <pre data-status={scope.status}>
      {scope.status === "ready"
        ? JSON.stringify({ selected: scope.selected.id, teams: scope.teams.map((team) => team.id) })
        : ""}
    </pre>
  );
}

const twoTeams: Catalog = {
  selectedTeamId: "team-2",
  teams: [
    {
      id: "user-1",
      name: "Lawrence",
      personal: true,
      permissions: { use: true, manageAccounts: true },
    },
    {
      id: "team-2",
      name: "Manaflow",
      personal: false,
      permissions: { use: true, manageAccounts: true },
    },
    {
      id: "team-3",
      name: "No access",
      personal: false,
      permissions: { use: false, manageAccounts: false },
    },
  ],
};

describe("dashboard team scope", () => {
  beforeEach(() => {
    catalog = twoTeams;
    pending = false;
    searchTeam = null;
    queryData.clear();
    queryData.set(queryKey(["dashboard-team-catalog", "user-1"]), twoTeams);
    routerReplace.mockClear();
    routerRefresh.mockClear();
  });

  test("exposes the persisted team as current and only permitted teams", () => {
    catalog = twoTeams;
    pending = false;
    searchTeam = null;

    const html = renderToStaticMarkup(<Probe userId="user-1" />);

    expect(html).toContain('data-status="ready"');
    expect(html).toContain("&quot;selected&quot;:&quot;team-2&quot;");
    expect(html).toContain("[&quot;user-1&quot;,&quot;team-2&quot;]");
    expect(html).not.toContain("team-3");
  });

  test("lets a ?team= deep link win over the persisted scope, like the server", () => {
    catalog = twoTeams;
    searchTeam = "user-1";

    const html = renderToStaticMarkup(<Probe userId="user-1" />);

    expect(html).toContain("&quot;selected&quot;:&quot;user-1&quot;");
  });

  test("reports loading while the catalog loads and unavailable when signed out", () => {
    catalog = undefined;
    pending = true;
    expect(renderToStaticMarkup(<Probe userId="user-1" />)).toContain('data-status="loading"');

    pending = false;
    expect(renderToStaticMarkup(<Probe userId={null} />)).toContain('data-status="unavailable"');
  });

  test("selection order matches the coderouter page", () => {
    const teams = permittedTeams(twoTeams);
    expect(teams.map((team) => team.id)).toEqual(["user-1", "team-2"]);
    expect(selectedTeam(teams, "team-2", null).id).toBe("team-2");
    expect(selectedTeam(teams, "team-2", "user-1").id).toBe("user-1");
    expect(selectedTeam(teams, "stale", "missing").id).toBe("user-1");
    expect(selectedTeam(teams, null, null).id).toBe("user-1");
  });

  test("rejects malformed catalogs instead of rendering them", () => {
    expect(parseTeamCatalog({ selectedTeamId: null, teams: [] })).toEqual({
      selectedTeamId: null,
      teams: [],
    });
    expect(parseTeamCatalog({ teams: [{ id: "a" }] })).toBeNull();
    expect(
      parseTeamCatalog({
        selectedTeamId: null,
        teams: [twoTeams.teams[0], twoTeams.teams[0]],
      }),
    ).toBeNull();
    expect(parseTeamCatalog({ selectedTeamId: " padded ", teams: [] })).toBeNull();
  });

  test("a stalled team switch aborts and releases its caller", async () => {
    const originalFetch = globalThis.fetch;
    let expire: (() => void) | undefined;
    let signal: AbortSignal | null | undefined;
    const timers = spyOn(globalThis, "setTimeout").mockImplementation(((callback: () => void) => {
      expire = callback;
      return 1;
    }) as unknown as typeof setTimeout);
    const clear = spyOn(globalThis, "clearTimeout");
    globalThis.fetch = ((_input, init) => new Promise<Response>((_resolve, reject) => {
      signal = init?.signal;
      signal?.addEventListener("abort", () => reject(signal?.reason), { once: true });
    })) as typeof fetch;
    try {
      const scope = useDashboardTeamScope("user-1");
      if (scope.status !== "ready") throw new Error("Expected a ready team scope");
      const switching = scope.switchTeam(twoTeams.teams[0]!);
      expect(signal).toBeInstanceOf(AbortSignal);
      expect(expire).toBeDefined();
      expire!();
      await expect(switching).rejects.toThrow();
      expect(signal?.aborted).toBe(true);
      expect(clear).toHaveBeenCalled();
    } finally {
      globalThis.fetch = originalFetch;
      timers.mockRestore();
      clear.mockRestore();
    }
  });

  test("updates the selected team and dashboard scope before the server responds", async () => {
    const originalFetch = globalThis.fetch;
    let resolveFetch: ((response: Response) => void) | undefined;
    globalThis.fetch = (() => new Promise<Response>((resolve) => {
      resolveFetch = resolve;
    })) as typeof fetch;
    try {
      const scope = useDashboardTeamScope("user-1");
      if (scope.status !== "ready") throw new Error("Expected a ready team scope");

      const switching = scope.switchTeam(twoTeams.teams[0]!);

      expect(queryData.get(queryKey(["dashboard-team-catalog", "user-1"]))).toMatchObject({
        selectedTeamId: "user-1",
      });
      expect(routerReplace).toHaveBeenCalledWith("/dashboard/coderouter?team=user-1");
      expect(routerRefresh).not.toHaveBeenCalled();

      resolveFetch!(new Response(null, { status: 204 }));
      await switching;

      expect(routerReplace).toHaveBeenLastCalledWith("/dashboard/coderouter");
      expect(routerRefresh).toHaveBeenCalledTimes(1);
    } finally {
      globalThis.fetch = originalFetch;
    }
  });

  test("rolls back the optimistic scope when the server rejects the switch", async () => {
    const originalFetch = globalThis.fetch;
    globalThis.fetch = (async () => new Response(null, { status: 500 })) as typeof fetch;
    try {
      const scope = useDashboardTeamScope("user-1");
      if (scope.status !== "ready") throw new Error("Expected a ready team scope");

      await expect(scope.switchTeam(twoTeams.teams[0]!)).rejects.toThrow("Could not switch dashboard team");

      expect(queryData.get(queryKey(["dashboard-team-catalog", "user-1"]))).toMatchObject({
        selectedTeamId: "team-2",
      });
      expect(routerReplace).toHaveBeenLastCalledWith("/dashboard/coderouter");
      expect(routerRefresh).not.toHaveBeenCalled();
    } finally {
      globalThis.fetch = originalFetch;
    }
  });
});
