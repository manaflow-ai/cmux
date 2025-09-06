import { beforeEach, describe, expect, test, vi } from "vitest";
import { convexTest } from "convex-test";
import schema from "./schema";
import { modules } from "./test.setup";
import { api } from "./_generated/api";

const TEAM_ID = "123e4567-e89b-12d3-a456-426614170002";

describe("workspaceSettings queries and mutations", () => {
  beforeEach(() => {
    vi.useFakeTimers();
    vi.setSystemTime(new Date("2024-01-01T00:00:00Z"));
  });

  test("get returns null then update upserts and get returns row", async () => {
    const t = convexTest(schema, modules);
    await t.run(async (ctx) => {
      const now = Date.now();
      await ctx.db.insert("teamMemberships", { teamId: TEAM_ID, userId: "u1", createdAt: now, updatedAt: now });
    });
    const asUser = t.withIdentity({ subject: "u1" });

    const none = await asUser.query(api.workspaceSettings.get, { teamSlugOrId: TEAM_ID });
    expect(none).toBeNull();

    await asUser.mutation(api.workspaceSettings.update, { teamSlugOrId: TEAM_ID, worktreePath: "/work/trees", autoPrEnabled: true });
    const after = await asUser.query(api.workspaceSettings.get, { teamSlugOrId: TEAM_ID });
    expect(after?.worktreePath).toBe("/work/trees");
    expect(after?.autoPrEnabled).toBe(true);

    // Update existing
    vi.setSystemTime(new Date("2024-01-02T00:00:00Z"));
    await asUser.mutation(api.workspaceSettings.update, { teamSlugOrId: TEAM_ID, worktreePath: "/w", autoPrEnabled: false });
    const after2 = await asUser.query(api.workspaceSettings.get, { teamSlugOrId: TEAM_ID });
    expect(after2?.worktreePath).toBe("/w");
    expect(after2?.autoPrEnabled).toBe(false);
  });
});

