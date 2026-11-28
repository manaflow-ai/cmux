import { describe, expect, test } from "bun:test";
import { legacyTeamHashRedirect } from "../dashboard-app/routes/legacy-team-hash";

// `/dashboard/team` is the legacy Hexclave account settings URL. Stack emails
// and old bookmarks still link there with a hash. The route-level redirect
// (history replace, locale basepath) is covered in dashboard-router.test.tsx.
type Case = readonly [hash: string, to: string, params: { teamId: string } | undefined];

describe("legacyTeamHashRedirect", () => {
  test.each<Case>([
    ["#team-team_123", "/dashboard/teams/$teamId", { teamId: "team_123" }],
    ["#team-a%2Fb", "/dashboard/teams/$teamId", { teamId: "a/b" }],
    ["team-abc", "/dashboard/teams/$teamId", { teamId: "abc" }],
    ["#team-creation", "/dashboard/teams/new", undefined],
    ["#profile", "/dashboard/settings", undefined],
    ["#auth", "/dashboard/settings/auth", undefined],
    ["#notifications", "/dashboard/settings/notifications", undefined],
    ["#sessions", "/dashboard/settings/sessions", undefined],
    ["#api-keys", "/dashboard/settings/api-keys", undefined],
    ["#settings", "/dashboard/settings/account", undefined],
    ["#payments", "/dashboard/billing", undefined],
    ["", "/dashboard/settings", undefined],
    ["#", "/dashboard/settings", undefined],
    ["#team-", "/dashboard/settings", undefined],
    ["#unknown", "/dashboard/settings", undefined],
    ["#constructor", "/dashboard/settings", undefined],
    ["#%E0%A4%A", "/dashboard/settings", undefined],
  ])("maps %p to %p", (hash, to, params) => {
    const { options } = legacyTeamHashRedirect(hash);
    expect(options.to as string).toBe(to);
    expect(options.params as unknown).toEqual(params);
    expect(options.replace).toBe(true);
  });
});
