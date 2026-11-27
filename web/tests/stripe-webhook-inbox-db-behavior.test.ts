// Database-backed proof of the Stripe webhook inbox contract the in-memory
// inbox (tests/helpers/stripe-webhook-inbox-memory.ts) mirrors: one stored
// copy per event, one live lease per Stripe object, fenced writes, and the
// drain's due order. Gated like the other *-db-behavior tests.

import { afterAll, beforeAll, beforeEach, describe, expect, test } from "bun:test";
import postgres, { type Sql } from "postgres";

import { closeCloudDbForTests } from "../db/client";
import { createDrizzleStripeWebhookInbox } from "../services/billing/stripeWebhookInbox";
import { runBillingAlertChecks } from "../services/observability/billingAlerts";

const runDbTests = process.env.CMUX_DB_TEST === "1";
const dbTest = runDbTests ? test : test.skip;
const inbox = createDrizzleStripeWebhookInbox();
const MINUTE = 60_000;

let sql: Sql | null = null;

beforeAll(() => {
  if (!runDbTests) return;
  const databaseURL = process.env.DIRECT_DATABASE_URL ?? process.env.DATABASE_URL;
  if (!databaseURL) throw new Error("DATABASE_URL is required when CMUX_DB_TEST=1");
  sql = postgres(databaseURL, { max: 2 });
});

beforeEach(async () => {
  if (!sql) return;
  await sql`truncate stripe_webhook_events`;
});

afterAll(async () => {
  await closeCloudDbForTests();
  await sql?.end();
});

function entry(id: string, objectKey: string | null = "sub_1", type = "customer.subscription.updated", created?: Date) {
  return { id, type, payloadHash: `hash_${id}`, objectKey, createdAt: created ?? null };
}

describe("Stripe webhook inbox store", () => {
  dbTest("stores an event once and reports whether a stored copy was processed", async () => {
    expect(await inbox.record(entry("evt_1"))).toEqual({ processed: false });
    expect(await inbox.record(entry("evt_1"))).toEqual({ processed: false });
    const claim = (await inbox.claim("evt_1", new Date(), new Date(Date.now() + MINUTE)))!;
    expect(await inbox.complete(claim, null)).toBe(true);
    expect(await inbox.record(entry("evt_1"))).toEqual({ processed: true });
    const [row] = await sql!<{ count: number }[]>`select count(*)::int as count from stripe_webhook_events`;
    expect(row.count).toBe(1);
  });

  dbTest("holds one live lease per Stripe object, under concurrent claims", async () => {
    for (const id of ["evt_a", "evt_b", "evt_c"]) await inbox.record(entry(id));
    await inbox.record(entry("evt_other", "sub_2"));
    const now = new Date();
    const lease = new Date(now.getTime() + MINUTE);
    const claims = await Promise.all(["evt_a", "evt_b", "evt_c", "evt_other"].map((id) => inbox.claim(id, now, lease)));
    const sub1 = claims.slice(0, 3).filter(Boolean);
    expect(sub1).toHaveLength(1);
    expect(claims[3]).toMatchObject({ id: "evt_other", attempts: 1 });

    // Once the holder is done, a sibling can run.
    expect(await inbox.complete(sub1[0]!, null)).toBe(true);
    const waiting = ["evt_a", "evt_b", "evt_c"].find((id) => id !== sub1[0]!.id)!;
    expect(await inbox.claim(waiting, now, lease)).toMatchObject({ id: waiting });
  });

  dbTest("a lapsed lease can be taken over, and the old holder's writes are refused", async () => {
    await inbox.record(entry("evt_1"));
    const start = new Date();
    const stale = (await inbox.claim("evt_1", start, new Date(start.getTime() + 1_000)))!;
    expect(await inbox.claim("evt_1", start, new Date(start.getTime() + MINUTE))).toBeNull();
    const later = new Date(start.getTime() + 2_000);
    const current = (await inbox.claim("evt_1", later, new Date(later.getTime() + MINUTE)))!;
    expect(current.attempts).toBe(2);

    expect(await inbox.fail(stale, "late", later)).toBe(false);
    expect(await inbox.complete(stale, null)).toBe(false);
    expect(await inbox.complete(current, "foreign_checkout")).toBe(true);
    const [row] = await sql!<{ processed: boolean; skip_reason: string | null; lease_expires_at: Date | null }[]>`
      select processed_at is not null as processed, skip_reason, lease_expires_at from stripe_webhook_events where id = 'evt_1'
    `;
    expect(row).toEqual({ processed: true, skip_reason: "foreign_checkout", lease_expires_at: null });
  });

  dbTest("a failure keeps the error, releases the lease and schedules the next attempt", async () => {
    await inbox.record(entry("evt_1"));
    const now = new Date();
    const claim = (await inbox.claim("evt_1", now, new Date(now.getTime() + MINUTE)))!;
    const retryAt = new Date(now.getTime() + 5 * MINUTE);
    expect(await inbox.fail(claim, "Stack Auth unavailable", retryAt)).toBe(true);

    expect(await inbox.due(now, new Date(now.getTime() - 60 * MINUTE), 10)).toEqual([]);
    expect(await inbox.due(retryAt, new Date(now.getTime() - 60 * MINUTE), 10)).toEqual(["evt_1"]);
    const [row] = await sql!<{ error: string; attempts: number; lease_expires_at: Date | null }[]>`
      select error, attempts, lease_expires_at from stripe_webhook_events where id = 'evt_1'
    `;
    expect(row).toEqual({ error: "Stack Auth unavailable", attempts: 1, lease_expires_at: null });
  });

  dbTest("a new event waits for the webhook before the drain takes it", async () => {
    await inbox.record(entry("evt_1"));
    const now = new Date();
    const since = new Date(now.getTime() - 60 * MINUTE);
    expect(await inbox.due(now, since, 10)).toEqual([]);
    expect(await inbox.due(new Date(now.getTime() + 3 * MINUTE), since, 10)).toEqual(["evt_1"]);
  });

  dbTest("finds a later applied event of the same object, and ignores skipped or earlier ones", async () => {
    const t = (seconds: number) => new Date(Date.UTC(2026, 9, 30, 0, 0, seconds));
    await inbox.record(entry("evt_old", "sub_1", "invoice.payment_failed", t(10)));
    await inbox.record(entry("evt_new", "sub_1", "customer.subscription.updated", t(20)));
    await inbox.record(entry("evt_skipped", "sub_1", "invoice.paid", t(30)));
    const now = new Date();
    const lease = new Date(now.getTime() + MINUTE);
    const skipped = (await inbox.claim("evt_skipped", now, lease))!;
    await inbox.complete(skipped, "subscription_unmapped");

    const old = { id: "evt_old", objectKey: "sub_1", createdAt: t(10) };
    expect(await inbox.supersededBy(old, ["customer.subscription.updated", "invoice.paid"])).toBeNull();

    const newer = (await inbox.claim("evt_new", now, lease))!;
    await inbox.complete(newer, null);
    expect(await inbox.supersededBy(old, ["customer.subscription.updated", "invoice.paid"])).toBe("evt_new");
    expect(await inbox.supersededBy(old, ["invoice.paid"])).toBeNull();
    expect(await inbox.supersededBy({ id: "evt_new", objectKey: "sub_1", createdAt: t(20) }, ["customer.subscription.updated"])).toBeNull();
  });

  dbTest("a later record fills a stored row's missing object key and keeps its schedule", async () => {
    await sql!`
      insert into stripe_webhook_events (id, type, payload_hash, next_attempt_at, lease_expires_at)
      values ('evt_legacy', 'charge.refunded', 'h', now() - interval '1 minute', now() - interval '1 minute')
    `;
    const created = new Date(Date.UTC(2026, 9, 30));
    expect(await inbox.record(entry("evt_legacy", "sub_1", "charge.refunded", created))).toEqual({ processed: false });
    await inbox.record(entry("evt_legacy", "sub_other", "charge.refunded", new Date()));
    const [row] = await sql!<{ object_key: string; event_created_at: Date; due: boolean }[]>`
      select object_key, event_created_at, next_attempt_at <= now() as due from stripe_webhook_events where id = 'evt_legacy'
    `;
    expect(row).toEqual({ object_key: "sub_1", event_created_at: created, due: true });

    // Now keyed, it waits while a sibling of the subscription holds a lease.
    await inbox.record(entry("evt_sibling"));
    const now = new Date();
    expect(await inbox.claim("evt_sibling", now, new Date(now.getTime() + MINUTE))).not.toBeNull();
    expect(await inbox.claim("evt_legacy", now, new Date(now.getTime() + MINUTE))).toBeNull();
  });

  dbTest("billing alerts page on events still unprocessed after the grace, across the retry window", async () => {
    await sql!`
      insert into stripe_webhook_events (id, type, payload_hash, error, processed_at, created_at) values
        ('evt_stuck_2d', 'invoice.paid', 'h', null, null, now() - interval '2 days'),
        ('evt_failing', 'customer.subscription.updated', 'h', 'Stack down', null, now() - interval '5 minutes'),
        ('evt_contention', 'invoice.paid', 'h', 'retryable: lease', null, now() - interval '5 minutes'),
        ('evt_fresh', 'invoice.paid', 'h', null, null, now() - interval '5 minutes'),
        ('evt_done', 'invoice.paid', 'h', null, now(), now() - interval '2 days'),
        ('evt_expired', 'invoice.paid', 'h', null, null, now() - interval '4 days')
    `;
    const sent: { key: string; body: string }[] = [];
    const summary = await runBillingAlertChecks({
      sendAlert: async (input) => {
        sent.push(input);
        return { sent: true, configured: true };
      },
      countUnsentPurchaseEmails: async () => 0,
    });

    expect(summary.webhookErrors).toEqual({ triggered: true, count: 2 });
    expect(sent[0]?.body).toContain("evt_stuck_2d");
    expect(sent[0]?.body).toContain("evt_failing");
    expect(sent[0]?.body).not.toContain("evt_contention");
    expect(sent[0]?.body).not.toContain("evt_fresh");
  });

  dbTest("a row the pre-inbox build is applying is held until that build is gone", async () => {
    // What the previous web build inserts before processing in its request.
    await sql!`insert into stripe_webhook_events (id, type, payload_hash) values ('evt_old_build', 'invoice.paid', 'h')`;
    const now = new Date();
    expect(await inbox.claim("evt_old_build", now, new Date(now.getTime() + MINUTE))).toBeNull();
    // A redelivery to the new build keys it, so its siblings wait too.
    expect(await inbox.record(entry("evt_old_build", "sub_1", "invoice.paid"))).toEqual({ processed: false });
    await inbox.record(entry("evt_sibling"));
    expect(await inbox.claim("evt_sibling", now, new Date(now.getTime() + MINUTE))).toBeNull();

    const later = new Date(now.getTime() + 16 * MINUTE);
    expect(await inbox.claim("evt_old_build", later, new Date(later.getTime() + MINUTE))).toMatchObject({ attempts: 1 });
  });

  dbTest("while an unkeyed row of the pre-inbox build is held, the inbox claims nothing", async () => {
    await sql!`insert into stripe_webhook_events (id, type, payload_hash) values ('evt_old_build', 'invoice.paid', 'h')`;
    await inbox.record(entry("evt_new", "sub_any"));
    await inbox.record(entry("evt_unkeyed", null, "charge.refunded"));
    const now = new Date();
    expect(await inbox.claim("evt_new", now, new Date(now.getTime() + MINUTE))).toBeNull();
    expect(await inbox.claim("evt_unkeyed", now, new Date(now.getTime() + MINUTE))).toBeNull();

    // The inbox's own unkeyed claims are not mistaken for that build's.
    const later = new Date(now.getTime() + 16 * MINUTE);
    expect(await inbox.claim("evt_unkeyed", later, new Date(later.getTime() + MINUTE))).toMatchObject({ attempts: 1 });
    expect(await inbox.claim("evt_new", later, new Date(later.getTime() + MINUTE))).toMatchObject({ attempts: 1 });
  });

  dbTest("rows stored before the inbox columns existed are drained", async () => {
    await sql!`
      insert into stripe_webhook_events (id, type, payload_hash, error, created_at, next_attempt_at, lease_expires_at)
      values ('evt_legacy', 'invoice.paid', 'h', 'retryable: lease', now() - interval '10 minutes', now() - interval '1 minute', now() - interval '1 minute')
    `;
    const now = new Date();
    expect(await inbox.due(now, new Date(now.getTime() - 60 * MINUTE), 10)).toEqual(["evt_legacy"]);
    expect(await inbox.claim("evt_legacy", now, new Date(now.getTime() + MINUTE))).toMatchObject({ attempts: 1 });
  });
});
