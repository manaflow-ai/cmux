// Database-backed proof of the personal plan allowances: an App Store Go
// subscriber gets Go hours (the database capacity guard and the app agree on
// the period), and Pro and Max meter compute units and saved disk on the
// subscription's own billing period from either store. Gated like the other
// *-db-behavior tests; every test uses its own user ids.

import { afterAll, afterEach, beforeAll, describe, expect, test } from "bun:test";
import postgres, { type Sql } from "postgres";
import { randomUUID } from "node:crypto";

import { closeCloudDbForTests } from "../db/client";
import { getGoVmUsage, GO_INCLUDED_VM_SECONDS } from "../services/vms/goUsage";
import { getPlanBudgetUsage, PLAN_BUDGETS } from "../services/vms/planUsage";

const runDbTests = process.env.CMUX_DB_TEST === "1";
const dbTest = runDbTests ? test : test.skip;
const HOUR = 60 * 60 * 1000;
const DAY = 24 * HOUR;

let sql: Sql | null = null;
const users: string[] = [];

beforeAll(() => {
  if (!runDbTests) return;
  const databaseURL = process.env.DIRECT_DATABASE_URL ?? process.env.DATABASE_URL;
  if (!databaseURL) throw new Error("DATABASE_URL is required when CMUX_DB_TEST=1");
  sql = postgres(databaseURL, { max: 2 });
});

afterAll(async () => {
  if (sql && users.length > 0) {
    await sql`delete from cloud_vms where user_id in ${sql(users)}`;
    await sql`delete from apple_subscriptions where user_id in ${sql(users)}`;
    await sql`delete from stripe_subscriptions where stack_user_id in ${sql(users)}`;
  }
  await closeCloudDbForTests();
  await sql?.end();
});

function db(): Sql {
  if (!sql) throw new Error("database is not connected");
  return sql;
}

function newUser(label: string): string {
  const id = `plan-allowance-${label}-${randomUUID()}`;
  users.push(id);
  return id;
}

async function appleSubscription(userId: string, planId: string, purchaseDate: Date, expiresAt: Date, period = "monthly") {
  await db()`insert into apple_subscriptions (
    original_transaction_id, user_id, bundle_id, environment, product_id, plan_id, status,
    purchase_date, original_purchase_date, expires_at, state_signed_at
  ) values (
    ${`otx-${userId}`}, ${userId}, 'com.cmux.app', 'Production', ${`com.cmux.app.${planId}.${period}`}, ${planId}, 'active',
    ${purchaseDate}, ${purchaseDate}, ${expiresAt}, ${purchaseDate}
  )`;
}

async function stripeSubscription(userId: string, planId: string, periodStart: Date, periodEnd: Date, id = `sub-${userId}`) {
  await db()`insert into stripe_subscriptions (id, customer_id, stack_user_id, status, plan, scope, current_period_end, raw)
    values (${id}, ${`cus-${userId}`}, ${userId}, 'active', ${planId}, 'user', ${periodEnd},
      ${db().json({ current_period_start: Math.floor(periodStart.getTime() / 1000) })})`;
}

/** A machine whose only runtime interval ran from `startedAt` to `endedAt`. */
async function machine(input: {
  readonly userId: string;
  readonly planId: string;
  readonly status: "running" | "paused";
  readonly reservation?: { vcpus: number; memoryMb: number; diskMb: number };
  readonly startedAt: Date;
  readonly endedAt: Date;
}) {
  const metadata = input.reservation ? { cmuxResourceReservation: input.reservation } : {};
  const [row] = await db()<{ id: string }[]>`insert into cloud_vms (user_id, billing_team_id, billing_plan_id, provider, image_id, status, provider_metadata)
    values (${input.userId}, ${input.userId}, ${input.planId}, 'freestyle', 'test', 'running', ${db().json(metadata)})
    returning id`;
  if (input.status === "paused") await db()`update cloud_vms set status = 'paused' where id = ${row!.id}`;
  await db()`update cloud_vm_runtime_intervals set started_at = ${input.startedAt}, ended_at = ${input.endedAt}
    where vm_id = ${row!.id}`;
  return row!.id;
}

describe("Go hours for App Store subscribers", () => {
  dbTest("an App Store Go subscription starts a Go machine and meters it on its own period", async () => {
    const now = new Date();
    const userId = newUser("apple-go");
    const purchased = new Date(now.getTime() - 3 * DAY);
    await appleSubscription(userId, "go", purchased, new Date(now.getTime() + 27 * DAY));

    const fresh = await getGoVmUsage(userId, now);
    expect(fresh?.periodStart.getTime()).toBe(purchased.getTime());
    expect(fresh?.remainingSeconds).toBe(GO_INCLUDED_VM_SECONDS);

    // The capacity guard accepts the start (it refused every App Store Go
    // subscriber before), and the meter counts the run.
    await machine({
      userId, planId: "go", status: "paused",
      reservation: { vcpus: 2, memoryMb: 4096, diskMb: 16384 },
      startedAt: new Date(now.getTime() - 41 * HOUR), endedAt: new Date(now.getTime() - HOUR),
    });
    const used = await getGoVmUsage(userId, now);
    expect(used?.usedSeconds).toBe(40 * 3600);
    expect(used?.remainingSeconds).toBe(0);
  });
});

describe("Pro and Max allowances", () => {
  const budgetSwitch = process.env.CMUX_VM_PLAN_BUDGETS;
  afterEach(() => {
    if (budgetSwitch === undefined) delete process.env.CMUX_VM_PLAN_BUDGETS;
    else process.env.CMUX_VM_PLAN_BUDGETS = budgetSwitch;
  });

  dbTest("Pro meters compute units and saved disk on the web subscription's period", async () => {
    const now = new Date();
    const userId = newUser("stripe-pro");
    const periodStart = new Date(now.getTime() - 2 * DAY);
    const periodEnd = new Date(now.getTime() + 28 * DAY);
    await stripeSubscription(userId, "pro", periodStart, periodEnd);
    // Off by default: the pricing page promises no hour limits.
    delete process.env.CMUX_VM_PLAN_BUDGETS;
    expect(await getPlanBudgetUsage(userId, now)).toBeNull();
    process.env.CMUX_VM_PLAN_BUDGETS = "on";
    // 10 hours of an 8 vCPU / 16 GB machine is 80 compute-hours; 4 hours of a
    // legacy machine without a recorded shape counts as the default 4 units.
    await machine({
      userId, planId: "pro", status: "paused",
      reservation: { vcpus: 8, memoryMb: 16384, diskMb: 65536 },
      startedAt: new Date(now.getTime() - 11 * HOUR), endedAt: new Date(now.getTime() - HOUR),
    });
    await machine({
      userId, planId: "pro", status: "paused",
      startedAt: new Date(now.getTime() - 5 * HOUR), endedAt: new Date(now.getTime() - HOUR),
    });
    // A run before the period started does not count.
    await machine({
      userId, planId: "pro", status: "paused",
      reservation: { vcpus: 4, memoryMb: 8192, diskMb: 32768 },
      startedAt: new Date(periodStart.getTime() - 10 * HOUR), endedAt: new Date(periodStart.getTime() - HOUR),
    });

    const usage = await getPlanBudgetUsage(userId, now);
    expect(usage).toMatchObject({ planId: "pro", includedComputeSeconds: PLAN_BUDGETS.pro.computeHours * 3600 });
    expect(usage!.periodEnd.getTime()).toBe(periodEnd.getTime());
    expect(usage!.usedComputeSeconds).toBe((80 + 16) * 3600);
    expect(usage!.retainedStorageMb).toBe(65536 + 32768 + 32768);
  });

  dbTest("an App Store Max subscription outranks a web Pro one; Founder's Edition has no allowance", async () => {
    const now = new Date();
    process.env.CMUX_VM_PLAN_BUDGETS = "on";
    const maxUser = newUser("apple-max");
    await stripeSubscription(maxUser, "pro", new Date(now.getTime() - DAY), new Date(now.getTime() + 29 * DAY));
    const purchased = new Date(now.getTime() - 5 * DAY);
    await appleSubscription(maxUser, "max", purchased, new Date(now.getTime() + 25 * DAY));
    const usage = await getPlanBudgetUsage(maxUser, now);
    expect(usage?.planId).toBe("max");
    expect(usage?.periodStart.getTime()).toBe(purchased.getTime());

    // A yearly App Store subscription resets the allowance every month.
    const yearly = newUser("apple-pro-yearly");
    const bought = new Date(now.getTime() - 40 * DAY);
    bought.setUTCDate(Math.min(bought.getUTCDate(), 28));
    await appleSubscription(yearly, "pro", bought, new Date(bought.getTime() + 365 * DAY), "yearly");
    const window = await getPlanBudgetUsage(yearly, now);
    const oneMonth = new Date(bought); oneMonth.setUTCMonth(bought.getUTCMonth() + 1);
    const twoMonths = new Date(bought); twoMonths.setUTCMonth(bought.getUTCMonth() + 2);
    expect(window?.planId).toBe("pro");
    expect(window?.periodStart.getTime()).toBe(oneMonth.getTime());
    expect(window?.periodEnd.getTime()).toBe(twoMonths.getTime());

    const founder = newUser("founder");
    await stripeSubscription(founder, "pro", new Date(now.getTime() - DAY), new Date(now.getTime() + 365 * DAY), `founders_${founder}`);
    expect(await getPlanBudgetUsage(founder, now)).toBeNull();
  });
});
