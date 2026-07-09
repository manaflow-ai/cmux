import { describe, expect, test } from "bun:test";

import {
  buildTeamInviteEmail,
  teamInviteThreadRef,
} from "../app/api/team/invite/team-invite-email";

describe("buildTeamInviteEmail", () => {
  test("builds a branded invite payload with the accept URL", () => {
    const email = buildTeamInviteEmail({
      from: "cmux <austin@manaflow.ai>",
      to: "ada@example.com",
      teamName: "Analytical Engines",
      inviterName: "Grace Hopper",
      acceptUrl: "https://cmux.test/en/dashboard/team/accept?code=abc",
      invitationId: "inv_123",
    });

    expect(email.from).toBe("cmux <austin@manaflow.ai>");
    expect(email.to).toEqual(["ada@example.com"]);
    expect(email.subject).toBe("Join Analytical Engines on cmux");
    expect(email.text).toContain("Grace invited you to join Analytical Engines on cmux.");
    expect(email.text).toContain("https://cmux.test/en/dashboard/team/accept?code=abc");
    expect(email.html).toContain("Accept invite");
    expect(email.headers["X-Entity-Ref-ID"]).toBe(teamInviteThreadRef("inv_123"));
  });
});
