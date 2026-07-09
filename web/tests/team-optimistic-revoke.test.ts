import { describe, expect, test } from "bun:test";

import { applyOptimisticRevoke } from "../app/[locale]/dashboard/team/optimistic";
import type { TeamSummaryDto } from "../services/team/invites";

describe("applyOptimisticRevoke", () => {
  test("returns next state plus rollback snapshot for one mutation path", () => {
    const previous: TeamSummaryDto = {
      teamId: "team-1",
      teamName: "Team One",
      seats: 2,
      currentUserRole: "admin",
      canManageTeam: true,
      members: [],
      invitations: [
        { id: "inv-1", email: "a@example.com", createdAt: null, acceptUrl: null, role: "member" },
        { id: "inv-2", email: "b@example.com", createdAt: null, acceptUrl: null, role: "member" },
      ],
    };

    const mutation = applyOptimisticRevoke(previous, "inv-1", "req-1");

    expect(mutation.requestId).toBe("req-1");
    expect(mutation.previous).toBe(previous);
    expect(mutation.next.invitations.map((invite) => invite.id)).toEqual(["inv-2"]);
  });
});
