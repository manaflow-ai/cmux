import { beforeEach, describe, expect, mock, test } from "bun:test";
import { call, ORPCError } from "@orpc/server";

const TEAM_ID = "11111111-1111-4111-8111-111111111111";
let allowTeamApiKeys = true;
let access: { ok: true; access: unknown } | { ok: false; refusal: { code: string; status: number } };

mock.module("@/services/teams/http", () => ({
  authenticateTeamRequest: async () => ({ ok: true, user: { id: "user-1" } }),
}));

const realAccess = await import("../services/teams/access");
mock.module("@/services/teams/access", () => ({
  ...realAccess,
  requireTeamAccess: async (_user: unknown, _teamId: string, options: { permission?: string }) => {
    expect(options.permission).toBe("manageApiKeys");
    return access;
  },
}));

mock.module("@/app/lib/stack", () => ({
  isStackConfigured: () => true,
  getStackServerApp: () => ({
    getProject: async () => ({ config: { allowTeamApiKeys } }),
    getTeam: async () => ({
      listApiKeys: async () => [{
        id: "k1",
        description: "deploy",
        createdAt: new Date("2026-09-02T00:00:00.000Z"),
        expiresAt: null,
        manuallyRevokedAt: null,
        value: { lastFour: "wxyz" },
        whyInvalid: () => null,
      }],
    }),
  }),
}));

const { teamsRouter } = await import("../orpc/server/dashboard/teams");

const context = { request: new Request("https://cmux.test/api/dashboard/rpc"), serverPrefetch: true };

beforeEach(() => {
  allowTeamApiKeys = true;
  access = { ok: true, access: { team: { id: TEAM_ID } } };
});

describe("teams.apiKeys", () => {
  test("lists the team's keys for a viewer who may manage them", async () => {
    expect(await call(teamsRouter.apiKeys, { teamId: TEAM_ID }, { context })).toEqual({
      enabled: true,
      keys: [{
        id: "k1",
        description: "deploy",
        createdAt: "2026-09-02T00:00:00.000Z",
        expiresAt: null,
        manuallyRevokedAt: null,
        lastFour: "wxyz",
        whyInvalid: null,
      }],
    });
  });

  test("a project without team API keys answers disabled instead of failing", async () => {
    allowTeamApiKeys = false;
    expect(await call(teamsRouter.apiKeys, { teamId: TEAM_ID }, { context })).toEqual({ enabled: false, keys: [] });
  });

  test("a viewer without the permission gets a declared FORBIDDEN", async () => {
    access = { ok: false, refusal: { code: "forbidden", status: 403 } };
    const error = await call(teamsRouter.apiKeys, { teamId: TEAM_ID }, { context }).catch((caught: unknown) => caught);
    expect(error).toBeInstanceOf(ORPCError);
    const refusal = error as ORPCError<string, { reason: string }>;
    expect([refusal.code, refusal.status, refusal.data.reason]).toEqual(["FORBIDDEN", 403, "forbidden"]);
  });
});
