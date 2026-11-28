// Database-backed proof that member removal completes on a one-connection
// pool. Production runs with CMUX_DB_POOL_MAX=1, so any query inside the
// per-team admin lock that asks the pool for a second connection waits
// forever. Gated like the other *-db-behavior tests.

import { afterAll, describe, expect, test } from "bun:test";
import { closeCloudDbForTests } from "../db/client";
import { requireTeamAccess } from "../services/teams/access";
import { removeMember } from "../services/teams/members";
import { ADMIN_ID, MEMBER_ID, standardTeam, TEAM_ID } from "./teams-fixture";

const runDbTests = process.env.CMUX_DB_TEST === "1";
const dbTest = runDbTests ? test : test.skip;
const previousPoolMax = process.env.CMUX_DB_POOL_MAX;

afterAll(async () => {
  await closeCloudDbForTests();
  if (previousPoolMax === undefined) delete process.env.CMUX_DB_POOL_MAX;
  else process.env.CMUX_DB_POOL_MAX = previousPoolMax;
});

async function settlesWithin<T>(ms: number, operation: Promise<T>): Promise<"settled" | "timed out"> {
  let timer: ReturnType<typeof setTimeout> | undefined;
  const timeout = new Promise<"timed out">((resolve) => { timer = setTimeout(() => resolve("timed out"), ms); });
  const result = await Promise.race([operation.then(() => "settled" as const, () => "settled" as const), timeout]);
  clearTimeout(timer);
  return result;
}

describe("team member removal under the admin lock", () => {
  dbTest("an admin removal finishes with a single pool connection", async () => {
    await closeCloudDbForTests();
    process.env.CMUX_DB_POOL_MAX = "1";
    const stack = standardTeam();
    const admin = await requireTeamAccess({ id: ADMIN_ID }, TEAM_ID, { stack: stack.app() });
    if (!admin.ok) throw new Error("access refused");
    expect(await settlesWithin(10_000, removeMember(admin.access, MEMBER_ID, { stack: stack.app() }))).toBe("settled");
    expect(stack.calls).toContain(`removeUser:${TEAM_ID}:${MEMBER_ID}`);
  }, 30_000);
});
