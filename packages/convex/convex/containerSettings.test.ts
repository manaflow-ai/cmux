import { beforeEach, describe, expect, test, vi } from "vitest";
import { convexTest } from "convex-test";
import schema from "./schema";
import { modules } from "./test.setup";
import { api } from "./_generated/api";

const TEAM_ID = "123e4567-e89b-12d3-a456-426614170003";

describe("containerSettings queries and mutations", () => {
  beforeEach(() => {
    vi.useFakeTimers();
    vi.setSystemTime(new Date("2024-01-01T00:00:00Z"));
  });

  test("get returns defaults, update upserts, getEffective merges", async () => {
    const t = convexTest(schema, modules);
    await t.run(async (ctx) => {
      const now = Date.now();
      await ctx.db.insert("teamMemberships", { teamId: TEAM_ID, userId: "u1", createdAt: now, updatedAt: now });
    });
    const asUser = t.withIdentity({ subject: "u1" });

    const defaults = await asUser.query(api.containerSettings.get, { teamSlugOrId: TEAM_ID });
    expect(defaults.maxRunningContainers).toBeDefined();

    await asUser.mutation(api.containerSettings.update, {
      teamSlugOrId: TEAM_ID,
      maxRunningContainers: 2,
      autoCleanupEnabled: false,
      minContainersToKeep: 1,
    });

    const effective = await asUser.query(api.containerSettings.getEffective, { teamSlugOrId: TEAM_ID });
    expect(effective.maxRunningContainers).toBe(2);
    expect(effective.autoCleanupEnabled).toBe(false);
    expect(effective.minContainersToKeep).toBe(1);
  });
});

