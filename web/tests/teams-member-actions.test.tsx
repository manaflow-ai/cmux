import { describe, expect, mock, test } from "bun:test";
import { renderToStaticMarkup } from "react-dom/server";
import { withDashboardRouter } from "./helpers/dashboard-router";
import { teamDetailFixture } from "./helpers/teams-ui-fixtures";
import { teamsNextIntlMock } from "./helpers/teams-ui-intl";

mock.module("next-intl", teamsNextIntlMock);
mock.module("@hexclave/next", () => ({
  useStackApp: () => ({ useProject: () => ({ config: { allowTeamApiKeys: true } }) }),
  useUser: () => null,
}));

const { memberActions } = await import("../dashboard-app/screens/teams/member-actions");
const { MembersTable } = await import("../dashboard-app/screens/teams/team-members");

const actionIds = (items: ReturnType<typeof memberActions>) =>
  items.map((item) => (item.disabledReason ? `${item.id}:${item.disabledReason}` : item.id));

describe("member row actions", () => {
  test("the only admin's own row keeps demote and leave visible but disabled, with the reason", () => {
    const detail = teamDetailFixture();
    const [viewer, bob] = detail.members;
    expect(actionIds(memberActions(detail, viewer!))).toEqual(["makeMember:lastAdmin", "leave:lastAdmin"]);
    expect(actionIds(memberActions(detail, bob!))).toEqual(["makeAdmin", "remove"]);
  });

  test("with a second admin the viewer can demote themselves and leave", () => {
    const base = teamDetailFixture();
    const detail = { ...base, members: base.members.map((member) => ({ ...member, role: "admin" as const })) };
    expect(actionIds(memberActions(detail, detail.members[0]!))).toEqual(["makeMember", "leave"]);
    expect(actionIds(memberActions(detail, detail.members[1]!))).toEqual(["makeMember", "remove"]);
  });

  test("an admin without remove permission can change roles but not remove", () => {
    const base = teamDetailFixture();
    const detail = { ...base, viewer: { ...base.viewer, permissions: { ...base.viewer.permissions, removeMembers: false } } };
    expect(actionIds(memberActions(detail, detail.members[1]!))).toEqual(["makeAdmin"]);
  });

  test("a member sees only Leave team on their own row and nothing on others", () => {
    const base = teamDetailFixture();
    const detail = {
      ...base,
      viewer: { ...base.viewer, userId: "user-2", role: "member" as const },
      members: base.members.map((member) => ({ ...member, isViewer: member.userId === "user-2" })),
    };
    expect(actionIds(memberActions(detail, detail.members[1]!))).toEqual(["leave"]);
    expect(actionIds(memberActions(detail, detail.members[0]!))).toEqual([]);
  });

  test("rows show the role as a badge and an actions menu, not a role select", async () => {
    const detail = teamDetailFixture();
    const html = renderToStaticMarkup((await withDashboardRouter(<MembersTable detail={detail} />, "/dashboard/teams/team-1/members")).element);
    expect(html).not.toContain("<select");
    expect(html).toContain('aria-label="Actions for Ada"');
    expect(html).toContain('aria-label="Actions for Bob"');
  });
});
