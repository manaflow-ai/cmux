import { beforeEach, describe, expect, mock, test } from "bun:test";
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

mock.module("@tanstack/react-query", () => ({
  useQuery: () => ({ data: catalog, isPending: pending }),
  useQueryClient: () => ({ setQueryData: () => undefined }),
}));

mock.module("next/navigation", () => ({
  useSearchParams: () => ({
    get: (name: string) => (name === "team" ? searchTeam : null),
    has: (name: string) => name === "team" && searchTeam !== null,
  }),
}));

mock.module("@/i18n/navigation", () => ({
  usePathname: () => "/dashboard/coderouter",
  useRouter: () => ({ replace: () => undefined, refresh: () => undefined }),
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
});
