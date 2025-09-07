import { beforeEach, describe, expect, test, vi } from "vitest";
import { convexTest } from "convex-test";
import schema from "./schema";
import { modules } from "./test.setup";
import { api } from "./_generated/api";

const TEAM_ID = "123e4567-e89b-12d3-a456-426614170001";

describe("apiKeys queries and mutations", () => {
  beforeEach(() => {
    vi.useFakeTimers();
    vi.setSystemTime(new Date("2024-01-01T00:00:00Z"));
  });

  test("upsert/getAll/getByEnvVar/remove/getAllForAgents", async () => {
    const t = convexTest(schema, modules);
    // Seed membership
    await t.run(async (ctx) => {
      const now = Date.now();
      await ctx.db.insert("teamMemberships", { teamId: TEAM_ID, userId: "user-1", createdAt: now, updatedAt: now });
    });
    const asUser = t.withIdentity({ subject: "user-1" });

    // Insert new key
    await asUser.mutation(api.apiKeys.upsert, {
      teamSlugOrId: TEAM_ID,
      envVar: "GEMINI_API_KEY",
      value: "v1",
      displayName: "Gemini",
      description: "k",
    });

    // Update existing key
    vi.setSystemTime(new Date("2024-01-02T00:00:00Z"));
    await asUser.mutation(api.apiKeys.upsert, {
      teamSlugOrId: TEAM_ID,
      envVar: "GEMINI_API_KEY",
      value: "v2",
      displayName: "Gemini 2",
      description: "k2",
    });

    const list = await asUser.query(api.apiKeys.getAll, { teamSlugOrId: TEAM_ID });
    expect(list.length).toBe(1);
    expect(list[0].envVar).toBe("GEMINI_API_KEY");
    expect(list[0].value).toBe("v2");

    const found = await asUser.query(api.apiKeys.getByEnvVar, { teamSlugOrId: TEAM_ID, envVar: "GEMINI_API_KEY" });
    expect(found?.displayName).toBe("Gemini 2");

    const agentMap = await asUser.query(api.apiKeys.getAllForAgents, { teamSlugOrId: TEAM_ID });
    expect(agentMap).toEqual({ GEMINI_API_KEY: "v2" });

    // Remove
    await asUser.mutation(api.apiKeys.remove, { teamSlugOrId: TEAM_ID, envVar: "GEMINI_API_KEY" });
    const after = await asUser.query(api.apiKeys.getAll, { teamSlugOrId: TEAM_ID });
    expect(after.length).toBe(0);
  });
});

