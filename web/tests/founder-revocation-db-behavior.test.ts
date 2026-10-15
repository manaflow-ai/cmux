// Database-backed proof of the Founder's Edition revocation: the revoke
// statement cancels only the Founder row and writes the marker, the plan
// resolver stops counting it, and the guarded upsert used by every checkout
// recorder cannot overwrite it. Gated like the other *-db-behavior tests.

import { afterAll, beforeAll, beforeEach, describe, expect, test } from "bun:test";
import { sql as drizzleSql } from "drizzle-orm";
import postgres, { type Sql } from "postgres";

import { cloudDb, closeCloudDbForTests } from "../db/client";
import { stripeSubscriptions } from "../db/schema";
import {
  FOUNDER_REVOKED_STATUS,
  founderAdminRevocationFromRaw,
  isAdminRevokedPurchase,
  makeFounderPurchaseStore,
  notAdminRevokedSql,
} from "../services/billing/founderRevocation";
import { activePersonalPlanForUser, stripeBillingStatusForUser } from "../services/billing/pro";

const runDbTests = process.env.CMUX_DB_TEST === "1";
const dbTest = runDbTests ? test : test.skip;
const USER = "user-founder-revocation";
const REVOCATION = { byUserId: "admin-1", byEmail: "admin@manaflow.ai", at: "2026-10-14T12:00:00.000Z" };

let sql: Sql | null = null;

beforeAll(() => {
  if (!runDbTests) return;
  const databaseURL = process.env.DIRECT_DATABASE_URL ?? process.env.DATABASE_URL;
  if (!databaseURL) throw new Error("DATABASE_URL is required when CMUX_DB_TEST=1");
  sql = postgres(databaseURL, { max: 2 });
});

beforeEach(async () => {
  if (!sql) return;
  await sql`delete from stripe_subscriptions where stack_user_id = ${USER}`;
});

afterAll(async () => {
  if (sql) await sql`delete from stripe_subscriptions where stack_user_id = ${USER}`;
  await closeCloudDbForTests();
  await sql?.end();
});

async function seed(db: Sql, id: string, plan: string, raw: Record<string, unknown>) {
  await db`insert into stripe_subscriptions (id, customer_id, stack_user_id, status, plan, scope, raw)
    values (${id}, 'cus_founder_revocation', ${USER}, 'active', ${plan}, 'user', ${db.json(raw as never)})`;
}

describe("founder revocation (database)", () => {
  dbTest("revokes only the Founder row and the resolver stops counting it", async () => {
    const db = sql!;
    await seed(db, "sub_founder_revocation", "pro", { metadata: { founders_edition: "true" } });
    await seed(db, "founders_cs_revocation", "pro", {});
    await seed(db, "sub_max_revocation", "max", { metadata: { app: "cmux", plan: "max" } });
    const store = makeFounderPurchaseStore();

    expect((await store.activeFounderPurchaseIds(USER)).sort()).toEqual([
      "founders_cs_revocation",
      "sub_founder_revocation",
    ]);
    // The admin UI shows Revoke Founder access from this flag.
    expect((await stripeBillingStatusForUser(USER)).hasFounderEntitlement).toBe(true);
    const revoked = await store.revokeActiveFounderPurchases(USER, REVOCATION);
    expect((await stripeBillingStatusForUser(USER)).hasFounderEntitlement).toBe(false);
    expect(revoked.sort()).toEqual(["founders_cs_revocation", "sub_founder_revocation"]);

    const rows = await db<{ id: string; status: string; raw: Record<string, unknown> }[]>`
      select id, status, raw from stripe_subscriptions where stack_user_id = ${USER} order by id`;
    const byId = new Map(rows.map((row) => [row.id, row]));
    expect(byId.get("sub_max_revocation")?.status).toBe("active");
    expect(byId.get("sub_max_revocation")?.raw).toEqual({ metadata: { app: "cmux", plan: "max" } });
    for (const id of revoked) {
      expect(byId.get(id)?.status).toBe(FOUNDER_REVOKED_STATUS);
      expect(founderAdminRevocationFromRaw(byId.get(id)?.raw)).toMatchObject({ ...REVOCATION, previousStatus: "active" });
      expect(await isAdminRevokedPurchase(cloudDb(), ["pi_unrelated", id])).toBe(true);
    }
    expect(await isAdminRevokedPurchase(cloudDb(), ["sub_max_revocation"])).toBe(false);
    expect(await activePersonalPlanForUser(USER)).toBe("max");
    expect(await store.revokeActiveFounderPurchases(USER, REVOCATION)).toEqual([]);

    await db`delete from stripe_subscriptions where id = 'sub_max_revocation'`;
    expect(await activePersonalPlanForUser(USER)).toBeNull();
  });

  dbTest("an old Founder row behind many newer personal rows is still found and revoked", async () => {
    const db = sql!;
    // Inserted after the newer rows so a capped, unordered read returns it last.
    for (let index = 0; index < 120; index += 1) {
      await db`insert into stripe_subscriptions (id, customer_id, stack_user_id, status, plan, scope, raw, updated_at)
        values (${`sub_newer_${index}`}, 'cus_founder_revocation', ${USER}, 'active', 'pro', 'user',
          ${db.json({ metadata: { app: "cmux", plan: "pro" } })}, now() + make_interval(secs => ${index + 1}))`;
    }
    await db`insert into stripe_subscriptions (id, customer_id, stack_user_id, status, plan, scope, raw, updated_at)
      values ('sub_founder_old', 'cus_founder_revocation', ${USER}, 'active', 'pro', 'user',
        ${db.json({ metadata: { founders_edition: "true" } })}, now() - interval '400 days')`;
    const store = makeFounderPurchaseStore();
    expect(await store.activeFounderPurchaseIds(USER)).toEqual(["sub_founder_old"]);
    expect((await stripeBillingStatusForUser(USER)).hasFounderEntitlement).toBe(true);
    expect(await store.revokeActiveFounderPurchases(USER, REVOCATION)).toEqual(["sub_founder_old"]);
    const [{ count }] = await db<{ count: string }[]>`
      select count(*)::text as count from stripe_subscriptions where stack_user_id = ${USER} and status = 'active'`;
    expect(count).toBe("120");
  });

  dbTest("the guarded recorder upsert cannot re-activate a revoked row", async () => {
    const db = sql!;
    await seed(db, "sub_founder_replay", "pro", { metadata: { founders_edition: "true" } });
    await makeFounderPurchaseStore().revokeActiveFounderPurchases(USER, REVOCATION);

    // Same statement shape as upsertStripeSubscription in purchase.ts.
    const replay = {
      id: "sub_founder_replay",
      customerId: "cus_founder_revocation",
      stackUserId: USER,
      status: "active",
      plan: "pro",
      scope: "user",
      raw: { metadata: { founders_edition: "true" } },
    };
    await cloudDb()
      .insert(stripeSubscriptions)
      .values(replay)
      .onConflictDoUpdate({
        target: stripeSubscriptions.id,
        set: { status: replay.status, raw: replay.raw, updatedAt: drizzleSql`now()` },
        setWhere: notAdminRevokedSql(),
      });

    const [row] = await db<{ status: string; raw: Record<string, unknown> }[]>`
      select status, raw from stripe_subscriptions where id = 'sub_founder_replay'`;
    expect(row?.status).toBe(FOUNDER_REVOKED_STATUS);
    expect(founderAdminRevocationFromRaw(row?.raw)).not.toBeNull();
    expect(await activePersonalPlanForUser(USER)).toBeNull();
  });
});
