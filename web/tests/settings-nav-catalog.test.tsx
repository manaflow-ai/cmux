import { describe, expect, mock, test } from "bun:test";
import { renderToStaticMarkup } from "react-dom/server";
import { withDashboardRouter } from "./helpers/dashboard-router";

// Regression: the settings subnav listed teams from the Hexclave SDK cache,
// which the dashboard's own team mutations never refresh, so a deleted team
// stayed in the subnav. It reads the team catalog the mutations invalidate.

mock.module("next-intl", () => ({ useTranslations: () => (key: string) => key }));
mock.module("@hexclave/next", () => ({
  useStackApp: () => ({ useProject: () => ({ config: { allowUserApiKeys: false } }) }),
  useUser: () => ({ useTeams: () => [{ id: "stale-team", displayName: "Deleted Team", profileImageUrl: null }] }),
}));

const { SettingsNavWithAccount } = await import("../dashboard-app/screens/settings/settings-nav");
const { teamCatalogQuery } = await import("../dashboard-app/queries/teams");

describe("settings subnav teams", () => {
  test("come from the team catalog, without the personal entry", async () => {
    const { element, queryClient } = await withDashboardRouter(<SettingsNavWithAccount />, "/dashboard/settings");
    queryClient.setQueryData(teamCatalogQuery.queryKey, {
      selectedTeamId: null,
      teams: [
        { id: "user-1", name: "Me", personal: true, permissions: { use: true, manageAccounts: true } },
        { id: "team-a", name: "Acme", personal: false, permissions: { use: true, manageAccounts: true } },
      ],
    });
    const html = renderToStaticMarkup(element);
    expect(html).toContain("Acme");
    expect(html).toContain('href="/dashboard/teams/team-a"');
    expect(html).not.toContain("Deleted Team");
    expect(html).not.toContain('href="/dashboard/teams/user-1"');
  });
});
