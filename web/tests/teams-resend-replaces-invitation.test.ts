import { describe, expect, test } from "bun:test";
import { QueryClient } from "@tanstack/react-query";
import { resendInvitationMutation, teamQueryKeys, type TeamDetail } from "../dashboard-app/queries/teams";

// Regression: a resend replaces the Stack invitation (new id), but the cache
// kept the old id until a refetch, so a quick Revoke hit a 404 and the
// rollback showed the invitation again.
describe("resend invitation", () => {
  test("the cache holds the replacement invitation as soon as the resend succeeds", async () => {
    const client = new QueryClient();
    const detail = {
      invitations: [
        { id: "old", email: "x@example.com", role: "member", expiresAt: "2026-10-01T00:00:00.000Z" },
        { id: "other", email: "y@example.com", role: "admin", expiresAt: "2026-10-01T00:00:00.000Z" },
      ],
    } as unknown as TeamDetail;
    client.setQueryData(teamQueryKeys.detail("team-a"), detail);
    const replacement = { id: "new", email: "x@example.com", role: "member", expiresAt: "2026-10-08T00:00:00.000Z" };
    const options = { ...resendInvitationMutation(client, "team-a"), mutationFn: async () => ({ invitation: replacement }), onSettled: undefined };
    await client.getMutationCache().build(client, options).execute("old");
    const after = client.getQueryData<TeamDetail>(teamQueryKeys.detail("team-a"))!;
    expect(after.invitations.map((invitation) => invitation.id)).toEqual(["new", "other"]);
  });
});
