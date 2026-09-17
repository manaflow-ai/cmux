import { afterAll, beforeAll, beforeEach, describe, expect, test } from "bun:test";
import { randomUUID } from "node:crypto";
import postgres, { type Sql } from "postgres";
import { closeCloudDbForTests } from "../db/client";
import {
  accountHealthRecipientHash,
  defaultDependencies,
  runAccountHealthNotifications,
} from "../services/coderouter/accountHealthEmail";
import { deleteAccount } from "../services/coderouter/repository";

const runDbTests = process.env.CMUX_DB_TEST === "1";
const dbTest = runDbTests ? test : test.skip;
const AT = new Date("2026-09-03T22:00:00.000Z");

let sql: Sql | null = null;

beforeAll(() => {
  if (!runDbTests) return;
  const databaseURL = process.env.DIRECT_DATABASE_URL ?? process.env.DATABASE_URL;
  if (!databaseURL) throw new Error("DATABASE_URL is required when CMUX_DB_TEST=1");
  sql = postgres(databaseURL, { max: 4 });
});

afterAll(async () => {
  await closeCloudDbForTests();
  await sql?.end({ timeout: 5 });
});

beforeEach(async () => {
  if (!sql) return;
  await sql`truncate coderouter_account_health_deliveries, coderouter_claude_accounts, coderouter_accounts cascade`;
});

describe("coderouter account-health delivery db behavior", () => {
  dbTest("a changed retry batch omits delivered recipients and account removal clears receipts", async () => {
    if (!sql) throw new Error("no sql client");
    const accountId = randomUUID();
    const teamId = `team-account-health-${randomUUID()}`;
    await sql`
      insert into coderouter_accounts
        (id, team_id, provider, provider_account_id, label, state, last_failure_code)
      values
        (${accountId}, ${teamId}, 'codex', ${`provider-${accountId}`}, 'work', 'broken', 'invalid_grant')
    `;

    let failDown = true;
    const accepted: string[] = [];
    const base = defaultDependencies();
    const dependencies = {
      ...base,
      recipients: async () => [
        { email: "ok@example.com", name: null },
        { email: "down@example.com", name: null },
      ],
      teamName: async () => "manaflow",
      send: async (email: { readonly to: string }) => {
        if (failDown && email.to === "down@example.com") throw new Error("resend down");
        accepted.push(email.to);
      },
      fromEmail: () => "coderouter@cmux.com",
      now: () => AT,
    };

    const first = await runAccountHealthNotifications(dependencies);
    expect(first).toMatchObject({ accounts: 1, emails: 1, recipients: 2, failures: 1 });
    expect(accepted).toEqual(["ok@example.com"]);
    const afterFirst = await sql`
      select recipient_hash from coderouter_account_health_deliveries
      where source = 'subscription' and account_id = ${accountId}
    `;
    expect(afterFirst.map((row) => String(row.recipient_hash))).toEqual([
      accountHealthRecipientHash("ok@example.com"),
    ]);
    const [pending] = await sql`
      select broken_notified_at from coderouter_accounts where id = ${accountId}
    `;
    expect(pending?.broken_notified_at).toBeNull();

    failDown = false;
    const second = await runAccountHealthNotifications(dependencies);
    expect(second).toMatchObject({ accounts: 1, emails: 1, recipients: 1, failures: 0 });
    expect(accepted).toEqual(["ok@example.com", "down@example.com"]);
    const afterSecond = await sql`
      select recipient_hash from coderouter_account_health_deliveries
      where source = 'subscription' and account_id = ${accountId}
      order by recipient_hash
    `;
    expect(afterSecond.map((row) => String(row.recipient_hash)).sort()).toEqual([
      accountHealthRecipientHash("ok@example.com"),
      accountHealthRecipientHash("down@example.com"),
    ].sort());
    const [notified] = await sql`
      select broken_notified_at from coderouter_accounts where id = ${accountId}
    `;
    expect(new Date(notified?.broken_notified_at as string).toISOString()).toBe(AT.toISOString());

    await expect(deleteAccount({ teamId, accountId, now: AT })).resolves.toEqual({
      removed: true,
      lastAccount: true,
    });
    const [receiptCount] = await sql`
      select count(*)::int as count from coderouter_account_health_deliveries
      where source = 'subscription' and account_id = ${accountId}
    `;
    expect(Number(receiptCount?.count)).toBe(0);
  });
});
