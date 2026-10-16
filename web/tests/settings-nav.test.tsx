import { describe, expect, mock, test } from "bun:test";
import { renderToStaticMarkup } from "react-dom/server";
import { withDashboardRouter } from "./helpers/dashboard-router";

mock.module("next-intl", () => ({
  useTranslations: () => (key: string) => key,
}));

const { SettingsNav, settingsNavGroups } = await import("../dashboard-app/screens/settings/settings-nav");

const label = (key: string) => key;
const links = (groups: ReturnType<typeof settingsNavGroups>) =>
  groups.flatMap((group) => group.items.map((item) => item.link));

describe("settings navigation", () => {
  test("lists account sections, billing, teams, and create team in order", () => {
    const groups = settingsNavGroups({
      pathname: "/dashboard/settings",
      allowUserApiKeys: true,
      teams: [{ id: "team/1", displayName: "Manaflow", profileImageUrl: null }],
      label,
    });
    expect(links(groups)).toEqual([
      { to: "/dashboard/settings", activeOptions: { exact: true } },
      { to: "/dashboard/settings/auth" },
      { to: "/dashboard/settings/notifications" },
      { to: "/dashboard/settings/sessions" },
      { to: "/dashboard/settings/api-keys" },
      { to: "/dashboard/settings/account" },
      { to: "/dashboard/billing" },
      { to: "/dashboard/teams/$teamId", params: { teamId: "team/1" } },
      { to: "/dashboard/teams/new" },
    ]);
  });

  test("groups the hub into Account, Billing, and Teams", () => {
    const groups = settingsNavGroups({
      pathname: "/dashboard/billing",
      allowUserApiKeys: false,
      teams: [{ id: "t1", displayName: "Acme", profileImageUrl: null }],
      label,
    });
    expect(groups.map((group) => [group.id, group.label])).toEqual([
      ["account", "accountGroup"],
      ["billing", "billingGroup"],
      ["teams", "teamsGroup"],
    ]);
    const billing = groups.find((group) => group.id === "billing")!;
    expect(billing.items.map((item) => [item.link.to, item.label, item.active])).toEqual([
      ["/dashboard/billing", "planBilling", true],
    ]);
  });

  test("the teams list page marks no single team active", () => {
    const groups = settingsNavGroups({
      pathname: "/dashboard/teams",
      allowUserApiKeys: false,
      teams: [{ id: "t1", displayName: "Acme", profileImageUrl: null }],
      label,
    });
    expect(groups.flatMap((group) => group.items).filter((item) => item.active)).toEqual([]);
  });

  test("hides API keys when the project disallows user API keys", () => {
    const groups = settingsNavGroups({ pathname: "/dashboard/settings", allowUserApiKeys: false, teams: [], label });
    expect(links(groups)).not.toContainEqual({ to: "/dashboard/settings/api-keys" });
  });

  test("marks only the current page active; profile matches exactly", () => {
    const groups = settingsNavGroups({
      pathname: "/dashboard/settings/sessions",
      allowUserApiKeys: true,
      teams: [],
      label,
    });
    const active = groups.flatMap((group) => group.items).filter((item) => item.active);
    expect(active.map((item) => item.link.to)).toEqual(["/dashboard/settings/sessions"]);
  });

  test("marks a team active on its tabs but not on a team whose id shares a prefix", () => {
    const groups = settingsNavGroups({
      pathname: "/dashboard/teams/a/members",
      allowUserApiKeys: false,
      teams: [
        { id: "a", displayName: "A", profileImageUrl: null },
        { id: "ab", displayName: "AB", profileImageUrl: null },
      ],
      label,
    });
    const active = groups.flatMap((group) => group.items).filter((item) => item.active);
    expect(active.map((item) => item.id)).toEqual(["team-a"]);
  });

  test("renders encoded hrefs and marks the current page with aria-current", async () => {
    const { element } = await withDashboardRouter(
      <SettingsNav teams={[{ id: "team/1", displayName: "Manaflow", profileImageUrl: null }]} />,
      "/dashboard/settings/auth",
    );
    const html = renderToStaticMarkup(element);
    expect(html).toContain('href="/dashboard/teams/team%2F1"');
    expect(html.match(/aria-current="page"/g)).toHaveLength(2); // desktop list and mobile disclosure
    expect(html).toMatch(/href="\/dashboard\/settings\/auth"[^>]*aria-current="page"|aria-current="page"[^>]*href="\/dashboard\/settings\/auth"/);
    expect(html).not.toMatch(/href="\/dashboard\/settings"[^>]*aria-current="page"/);
  });

  test("marks a team active on its own path and nested pages only", () => {
    const teams = [
      { id: "team/1", displayName: "Encoded", profileImageUrl: null },
      { id: "ab", displayName: "Prefix", profileImageUrl: null },
      { id: "abc", displayName: "Longer", profileImageUrl: null },
    ];
    // Router pathnames are decoded.
    const activeOn = (pathname: string) =>
      settingsNavGroups({ pathname, allowUserApiKeys: true, teams, label })
        .flatMap((group) => group.items)
        .filter((item) => item.active)
        .map((item) => item.id);
    expect(activeOn("/dashboard/teams/team/1/members")).toEqual(["team-team/1"]);
    expect(activeOn("/dashboard/teams/abc")).toEqual(["team-abc"]);
    expect(activeOn("/dashboard/teams/ab")).toEqual(["team-ab"]);
  });
});
