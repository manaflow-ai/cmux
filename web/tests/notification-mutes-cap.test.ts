// DB-backed test for the server-side per-user mute row cap. Gated by
// CMUX_DB_TEST=1 (CI's db:test), skipped locally, mirroring the rate-limit test.
// Proves an authenticated caller cannot grow the mutes table without bound: at
// the cap, a new workspace is rejected (409) while an already-muted one and an
// unmute still succeed.

import { afterAll, beforeAll, describe, expect, test } from "bun:test";
import postgres, { type Sql } from "postgres";

import { closeCloudDbForTests } from "../db/client";
import { MAX_MUTED_WORKSPACES_PER_USER } from "../services/apns/routePolicy";

const runDbTests = process.env.CMUX_DB_TEST === "1";
const dbTest = runDbTests ? test : test.skip;

let sql: Sql | null = null;
let postRoute: typeof import("../app/api/notifications/mutes/route").POST | null = null;

function muteRequest(workspaceId: string, muted: boolean): Request {
  return new Request("https://cmux.test/api/notifications/mutes", {
    method: "POST",
    headers: {
      authorization: "Bearer access-token",
      "x-stack-refresh-token": "refresh-token",
      "content-type": "application/json",
    },
    body: JSON.stringify({ workspaceId, muted }),
  });
}

beforeAll(async () => {
  if (!runDbTests) return;
  const databaseURL = process.env.DIRECT_DATABASE_URL ?? process.env.DATABASE_URL;
  if (!databaseURL) throw new Error("DATABASE_URL is required when CMUX_DB_TEST=1");
  sql = postgres(databaseURL, { max: 1 });

  // Stub auth to a fixed user; everything else hits the real DB.
  const { mock } = await import("bun:test");
  const getUser = mock(async () => ({
    id: "mutes-cap-user",
    displayName: null,
    primaryEmail: null,
    selectedTeam: null,
  }));
  mock.module("../app/lib/stack", () => ({
    getStackServerApp: () => ({ getUser }),
    isStackConfigured: () => true,
  }));
  postRoute = (await import("../app/api/notifications/mutes/route")).POST;
});

afterAll(async () => {
  await closeCloudDbForTests();
  await sql?.end();
});

describe("notification mutes server-side cap", () => {
  dbTest("rejects a new workspace at the cap but allows existing + unmute", async () => {
    if (!sql || !postRoute) throw new Error("test database not initialized");
    await sql`delete from notification_workspace_mutes where user_id = 'mutes-cap-user'`;

    // Seed the user at exactly the cap.
    const seed = Array.from({ length: MAX_MUTED_WORKSPACES_PER_USER }, (_, i) => ({
      user_id: "mutes-cap-user",
      workspace_id: `ws-${i}`,
    }));
    await sql`insert into notification_workspace_mutes ${sql(seed, "user_id", "workspace_id")}`;

    // A brand-new workspace is rejected.
    const overflow = await postRoute(muteRequest("ws-overflow", true));
    expect(overflow.status).toBe(409);
    expect(await overflow.json()).toMatchObject({ error: "too_many_muted_workspaces" });

    // Re-muting an already-muted workspace is a no-op success (no new row).
    const existing = await postRoute(muteRequest("ws-0", true));
    expect(existing.status).toBe(200);

    // Unmuting frees a slot.
    const unmute = await postRoute(muteRequest("ws-0", false));
    expect(unmute.status).toBe(200);
    const [{ value: countAfterUnmute }] = await sql<{ value: number }[]>`
      select count(*)::int as value from notification_workspace_mutes where user_id = 'mutes-cap-user'`;
    expect(countAfterUnmute).toBe(MAX_MUTED_WORKSPACES_PER_USER - 1);

    // Now a new workspace fits.
    const newOne = await postRoute(muteRequest("ws-new", true));
    expect(newOne.status).toBe(200);

    await sql`delete from notification_workspace_mutes where user_id = 'mutes-cap-user'`;
  });
});
