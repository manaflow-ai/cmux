import { beforeEach, describe, expect, test, vi } from "vitest";
import { convexTest } from "convex-test";
import schema from "./schema";
import { modules } from "./test.setup";
import { api } from "./_generated/api";
import type { Id } from "./_generated/dataModel";

const TEAM_ID = "123e4567-e89b-12d3-a456-426614170011";

describe("storage queries and mutations", () => {
  beforeEach(() => {
    vi.useFakeTimers();
    vi.setSystemTime(new Date("2024-01-01T00:00:00Z"));
  });

  test("generateUploadUrl returns a string and getUrl/getUrls error on missing id", async () => {
    const t = convexTest(schema, modules);
    const userId = "u1";
    await t.run(async (ctx) => {
      const now = Date.now();
      await ctx.db.insert("teamMemberships", { teamId: TEAM_ID, userId, createdAt: now, updatedAt: now });
    });
    const asUser = t.withIdentity({ subject: userId });

    const url = await asUser.mutation(api.storage.generateUploadUrl, { teamSlugOrId: TEAM_ID });
    expect(typeof url).toBe("string");

    const fakeId = "st_123" as unknown as Id<"_storage">;
    await expect(asUser.query(api.storage.getUrl, { teamSlugOrId: TEAM_ID, storageId: fakeId })).rejects.toThrowError();
    await expect(asUser.query(api.storage.getUrls, { teamSlugOrId: TEAM_ID, storageIds: [fakeId] })).rejects.toThrowError();
  });
});

