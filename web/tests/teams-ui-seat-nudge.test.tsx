import { describe, expect, mock, test } from "bun:test";
import { renderToStaticMarkup } from "react-dom/server";
import type React from "react";
import { teamDetailFixture } from "./helpers/teams-ui-fixtures";
import { teamsNextIntlMock } from "./helpers/teams-ui-intl";

mock.module("next-intl", teamsNextIntlMock);
mock.module("../i18n/navigation", () => ({
  Link: ({ href, children, className }: { href: string; children: React.ReactNode; className?: string }) => (
    <a href={href} className={className}>{children}</a>
  ),
  usePathname: () => "/dashboard/teams/team-1/members",
  useRouter: () => ({ push: () => undefined, refresh: () => undefined }),
}));
mock.module("@hexclave/next", () => ({
  useStackApp: () => ({ useProject: () => ({ config: { allowTeamApiKeys: true } }) }),
  useUser: () => null,
}));

const { seatOverage } = await import("../app/[locale]/dashboard/teams/team-logic");
const { SeatNudge } = await import("../app/[locale]/dashboard/teams/[teamId]/members/team-members");

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
  test("shows admins the overage with a link to team billing", () => {
    // Two members plus two pending invitations against three seats.
    const html = renderToStaticMarkup(<SeatNudge detail={teamDetailFixture()} />);
    expect(html).toContain('data-testid="seat-nudge"');
    expect(html).toContain("4 people are members or invited, but the plan has 3 seats");
    expect(html).toContain("add 1 seat");
    expect(html).toContain('href="/dashboard/teams/team-1/billing"');
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
