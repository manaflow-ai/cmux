import { beforeEach, describe, expect, test, vi } from "vitest";
import { convexTest } from "convex-test";
import schema from "./schema";
import { modules } from "./test.setup";
import { api } from "./_generated/api";

const TEAM_ID = "123e4567-e89b-12d3-a456-426614170004";

describe("comments queries and mutations", () => {
  beforeEach(() => {
    vi.useFakeTimers();
    vi.setSystemTime(new Date("2024-01-01T00:00:00Z"));
  });

  test("create/list/resolve/archive/replies", async () => {
    const t = convexTest(schema, modules);
    await t.run(async (ctx) => {
      const now = Date.now();
      await ctx.db.insert("teamMemberships", { teamId: TEAM_ID, userId: "u1", createdAt: now, updatedAt: now });
    });
    const asUser = t.withIdentity({ subject: "u1" });

    const url = "https://example.com/page";
    const page = "/page";
    const id = await asUser.mutation(api.comments.createComment, {
      teamSlugOrId: TEAM_ID,
      url,
      page,
      pageTitle: "Page",
      nodeId: "#main",
      x: 0.5,
      y: 0.5,
      content: "hello",
      profileImageUrl: undefined,
      userAgent: "ua",
      screenWidth: 1000,
      screenHeight: 800,
      devicePixelRatio: 2,
    });

    let list = await asUser.query(api.comments.listComments, { teamSlugOrId: TEAM_ID, url, page });
    expect(list.length).toBe(1);

    await asUser.mutation(api.comments.addReply, { teamSlugOrId: TEAM_ID, commentId: id, content: "reply" });
    const replies = await asUser.query(api.comments.getReplies, { teamSlugOrId: TEAM_ID, commentId: id });
    expect(replies.length).toBe(1);
    expect(replies[0].content).toBe("reply");

    await asUser.mutation(api.comments.resolveComment, { teamSlugOrId: TEAM_ID, commentId: id });
    list = await asUser.query(api.comments.listComments, { teamSlugOrId: TEAM_ID, url, page, resolved: true });
    expect(list.length).toBe(1);

    await asUser.mutation(api.comments.archiveComment, { teamSlugOrId: TEAM_ID, commentId: id, archived: true });
    list = await asUser.query(api.comments.listComments, { teamSlugOrId: TEAM_ID, url, page });
    expect(list.length).toBe(0);
    list = await asUser.query(api.comments.listComments, { teamSlugOrId: TEAM_ID, url, page, includeArchived: true });
    expect(list.length).toBe(1);
  });
});

