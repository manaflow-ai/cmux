import { describe, expect, mock, test } from "bun:test";
import { renderToStaticMarkup } from "react-dom/server";
import type { ReactNode } from "react";
import { withDashboardRouter } from "./helpers/dashboard-router";
import { teamDetailFixture } from "./helpers/teams-ui-fixtures";
import { teamsNextIntlMock } from "./helpers/teams-ui-intl";

mock.module("next-intl", teamsNextIntlMock);
mock.module("@hexclave/next", () => ({
  useStackApp: () => ({ useProject: () => ({ config: { allowTeamApiKeys: true } }) }),
  useUser: () => null,
}));

const { seatOverage } = await import("../dashboard-app/screens/teams/team-logic");
const { SeatNudge } = await import("../dashboard-app/screens/teams/team-members");

async function render(element: ReactNode): Promise<string> {
  return renderToStaticMarkup((await withDashboardRouter(element, "/dashboard/teams/team-1/members")).element);
}

describe("seat nudge math", () => {
  test("counts members plus pending invitations against paid seats", () => {
    expect(seatOverage({ seats: 3, memberCount: 2, pendingInvitations: 1 })).toBeNull();
    expect(seatOverage({ seats: 3, memberCount: 2, pendingInvitations: 2 })).toEqual({ seats: 3, used: 4, over: 1 });
    expect(seatOverage({ seats: 1, memberCount: 4, pendingInvitations: 0 })).toEqual({ seats: 1, used: 4, over: 3 });
  });

  test("never nudges when the team has no seat count", () => {
    expect(seatOverage({ seats: null, memberCount: 50, pendingInvitations: 20 })).toBeNull();
  });
});

describe("seat nudge notice", () => {
  test("shows admins the overage with a link to team billing", async () => {
    // Two members plus two pending invitations against three seats.
    const html = await render(<SeatNudge detail={teamDetailFixture()} />);
    expect(html).toContain('data-testid="seat-nudge"');
    expect(html).toContain("4 people are members or invited, but the plan has 3 seats");
    expect(html).toContain("add 1 seat");
    expect(html).toContain('href="/dashboard/teams/team-1/billing"');
  });

  test("encodes the team id in the billing link", async () => {
    const base = teamDetailFixture();
    const html = await render(<SeatNudge detail={{ ...base, team: { ...base.team, id: "team 1" } }} />);
    expect(html).toContain('href="/dashboard/teams/team%201/billing"');
  });

  test("hides the billing link from admins who cannot manage billing", () => {
    const base = teamDetailFixture();
    const html = renderToStaticMarkup(
      <SeatNudge
        detail={{
          ...base,
          viewer: { ...base.viewer, permissions: { ...base.viewer.permissions, manageBilling: false } },
        }}
      />,
    );
    expect(html).toContain('data-testid="seat-nudge"');
    expect(html).not.toContain("/billing");
  });

  test("stays hidden within the seat count and for members who cannot invite", () => {
    const base = teamDetailFixture();
    expect(renderToStaticMarkup(<SeatNudge detail={{ ...base, invitations: [] }} />)).toBe("");
    expect(
      renderToStaticMarkup(
        <SeatNudge
          detail={{
            ...base,
            viewer: { ...base.viewer, role: "member", permissions: { ...base.viewer.permissions, inviteMembers: false } },
          }}
        />,
      ),
    ).toBe("");
  });
});
