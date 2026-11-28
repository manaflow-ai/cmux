import { beforeEach, describe, expect, mock, test } from "bun:test";
import { renderToStaticMarkup } from "react-dom/server";
import { withDashboardRouter } from "./helpers/dashboard-router";
import { teamDetailFixture } from "./helpers/teams-ui-fixtures";
import { teamsNextIntlMock } from "./helpers/teams-ui-intl";

mock.module("next-intl", teamsNextIntlMock);
let detail = teamDetailFixture();
mock.module("../dashboard-app/screens/teams/team-shell", () => ({
  useTeamContext: () => detail,
  teamTabLink: (teamId: string, tab: string) => ({ to: `/dashboard/teams/${teamId}/${tab}` }),
}));
const { TeamMembers } = await import("../dashboard-app/screens/teams/team-members");

async function render() {
  return renderToStaticMarkup((await withDashboardRouter(<TeamMembers />)).element);
}

beforeEach(() => {
  detail = teamDetailFixture({
    invitations: [],
    billing: { planId: "pro", seats: null, memberLimit: 3, memberCount: 2, hasActiveSubscription: false },
  });
});

describe("team member capacity", () => {
  test("shows the team's total member limit before inviting, including the owner", async () => {
    const html = await render();
    expect(html).toContain("Members: 2 / 3");
    expect(html).toContain("Includes the owner. Pending invitations reserve spots.");
    expect(html).toContain("Spots remaining: 1");
    expect(html).toContain('href="/dashboard/teams/team-1/billing"');
    expect(html).toContain("Team is $60 per member/month. Personal subscriptions are billed separately.");
    expect(html.indexOf("Spots remaining")).toBeLessThan(html.indexOf("Send invitations"));
  });

  test("pending invitations reserve spots without being counted as joined members", async () => {
    detail = { ...detail, invitations: teamDetailFixture().invitations.slice(0, 1) };
    const html = await render();
    expect(html).toContain("Members: 2 / 3");
    expect(html).toContain("Pending invitations: 1");
    expect(html).toContain("Spots remaining: 0");
  });

  test("Max uses the server limit and over-cap rosters never show negative availability", async () => {
    detail = { ...detail, billing: { ...detail.billing, planId: "max", memberLimit: 1 } };
    expect(await render()).toContain("Spots remaining: 0");
  });

  test.each(["team", "free"])("an uncapped %s team has no cap or upgrade notice", async (planId) => {
    detail = { ...detail, billing: { ...detail.billing, planId, memberLimit: null } };
    const html = await render();
    expect(html).toContain("2 members");
    expect(html).not.toContain("Spots remaining");
    expect(html).not.toContain("Personal subscriptions are billed separately");
  });

  test("members do not see a billing action or availability computed from hidden invitations", async () => {
    detail = { ...detail, viewer: { ...detail.viewer, role: "member", permissions: {
      ...detail.viewer.permissions, inviteMembers: false, manageBilling: false, readMembers: false,
    } }, members: detail.members.slice(0, 1) };
    const html = await render();
    expect(html).toContain("Members: 2 / 3");
    expect(html).not.toContain("Spots remaining");
    expect(html).not.toContain('href="/dashboard/teams/team-1/billing"');
  });

  test("admins without invite permission do not see availability computed from hidden invitations", async () => {
    detail = { ...detail, viewer: { ...detail.viewer, permissions: {
      ...detail.viewer.permissions, inviteMembers: false,
    } } };
    const html = await render();
    expect(html).toContain("Members: 2 / 3");
    expect(html).not.toContain("Pending invitations: 2");
    expect(html).not.toContain("Spots remaining");
    expect(html).toContain('href="/dashboard/teams/team-1/billing"');
  });
});
