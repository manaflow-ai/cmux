import { describe, expect, test } from "bun:test";
import { settingsNavGroups } from "../app/[locale]/dashboard/settings/settings-nav";

const label = (key: string) => key;
const hrefs = (groups: ReturnType<typeof settingsNavGroups>) =>
  groups.flatMap((group) => group.items.map((item) => item.href));

describe("settings navigation", () => {
  test("lists account sections, billing, teams, and create team in order", () => {
    const groups = settingsNavGroups({
      pathname: "/dashboard/settings",
      allowUserApiKeys: true,
      teams: [{ id: "team/1", displayName: "Manaflow", profileImageUrl: null }],
      label,
    });
    expect(hrefs(groups)).toEqual([
      "/dashboard/settings",
      "/dashboard/settings/auth",
      "/dashboard/settings/notifications",
      "/dashboard/settings/sessions",
      "/dashboard/settings/api-keys",
      "/dashboard/settings/account",
      "/dashboard/billing",
      "/dashboard/teams/team%2F1",
      "/dashboard/teams/new",
    ]);
  });

  test("hides API keys when the project disallows user API keys", () => {
    const groups = settingsNavGroups({ pathname: "/dashboard/settings", allowUserApiKeys: false, teams: [], label });
    expect(hrefs(groups)).not.toContain("/dashboard/settings/api-keys");
  });

  test("marks only the current page active; profile matches exactly", () => {
    const groups = settingsNavGroups({
      pathname: "/dashboard/settings/sessions",
      allowUserApiKeys: true,
      teams: [],
      label,
    });
    const active = groups.flatMap((group) => group.items).filter((item) => item.active);
    expect(active.map((item) => item.href)).toEqual(["/dashboard/settings/sessions"]);
  });
});
