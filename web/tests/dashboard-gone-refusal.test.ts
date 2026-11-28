import { describe, expect, mock, test } from "bun:test";
import { call, ORPCError } from "@orpc/server";

mock.module("@/services/teams/http", () => ({
  authenticateTeamRequest: async () => ({ ok: true, user: { id: "user-1" } }),
}));

const { teamsRouter } = await import("../orpc/server/dashboard/teams");
const { dashboardRefusal } = await import("../orpc/server/dashboard/errors");

const context = { request: new Request("https://cmux.test/api/dashboard/rpc"), serverPrefetch: true };

describe("refusal statuses the routes return are declared", () => {
  test("an invalid invite link is a declared GONE with reason link_invalid, not a 500", async () => {
    const error = await call(teamsRouter.joinInfo, { token: "not-a-link-token" }, { context }).catch((caught: unknown) => caught);
    expect(error).toBeInstanceOf(ORPCError);
    const refusal = error as ORPCError<string, { reason: string }>;
    expect([refusal.code, refusal.status, refusal.data?.reason]).toEqual(["GONE", 410, "link_invalid"]);
  });

  test("payment required and not implemented keep their status and reason", () => {
    for (const [status, reason] of [[402, "plan_required"], [410, "invitation_invalid"], [501, "not_supported"]] as const) {
      const error = dashboardRefusal(status, reason);
      expect({ status: error.status, reason: (error.data as { reason?: string } | undefined)?.reason }).toEqual({ status, reason });
    }
  });
});
