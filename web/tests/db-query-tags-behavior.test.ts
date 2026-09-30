import { describe, expect, test } from "bun:test";
import { sql } from "drizzle-orm";
import { cloudDb } from "../db/client";
import { runWithCloudDbQueryTags } from "../db/queryTags";

const runDbTests = process.env.CMUX_DB_TEST === "1";
const dbTest = runDbTests ? test : test.skip;

describe("cloud db query tags on the wire", () => {
  dbTest("every statement the client sends carries the SQLCommenter comment", async () => {
    const db = cloudDb();
    const [outside] = await db.execute<{ q: string }>(sql`select current_query() as q`);
    expect(outside?.q).toContain("/*application='cmux-web'");
    // Drizzle issues the statement when the query is awaited, so the await
    // must happen inside the tag context, as it does inside a route handler.
    const [inside] = await runWithCloudDbQueryTags(
      { source: "app", route: "/api/devices/iroh/register" },
      async () => await db.execute<{ q: string }>(sql`select current_query() as q`),
    );
    expect(inside?.q).toContain("route='%2Fapi%2Fdevices%2Firoh%2Fregister'");
    expect(inside?.q).toContain("source='app'");
    // The comment is a suffix; the statement text is still first.
    expect(inside?.q?.startsWith("select current_query()")).toBe(true);
  });
});
