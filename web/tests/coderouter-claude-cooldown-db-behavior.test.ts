import { afterAll, beforeAll, beforeEach, expect, test } from "bun:test";
import postgres, { type Sql } from "postgres";
import { closeCloudDbForTests } from "../db/client";
import { markAccountCooldown, nextCapacityAvailableAt } from "../services/coderouter/repository";
import type { CredentialKeyService } from "../services/coderouter/encryption";
import {
  claudeAccountStore,
  createClaudeUpstreamService,
  parseClaudeUpstreamInput,
} from "../services/coderouter/claudeUpstream";

const enabled = process.env.CMUX_DB_TEST === "1";
const dbTest = enabled ? test : test.skip;
const CLAUDE_TEAM = "claude-cooldown-test";
const NATIVE_TEAM = "native-cooldown-test";
const FIVE_HOURS_MS = 5 * 60 * 60 * 1_000;
const ONE_HOUR_MS = 60 * 60 * 1_000;
const FIFTEEN_MINUTES_MS = 15 * 60 * 1_000;
const TWENTY_SECONDS_MS = 20 * 1_000;
let sql: Sql;

const testKeys: CredentialKeyService = {
  async generateDataKey() {
    return { plaintext: Buffer.alloc(32, 7), encrypted: Buffer.alloc(32, 7) };
  },
  async decryptDataKey() {
    return Buffer.alloc(32, 7);
  },
};
const claude = createClaudeUpstreamService({
  store: claudeAccountStore,
  keys: testKeys,
  keyId: "test-key",
});

beforeAll(() => {
  if (!enabled) return;
  sql = postgres(process.env.DIRECT_DATABASE_URL ?? process.env.DATABASE_URL!, { max: 5 });
  process.env.CODEROUTER_KMS_KEY_ID = "test-key";
});

beforeEach(async () => {
  if (!enabled) return;
  await sql`delete from coderouter_claude_accounts where team_id = ${CLAUDE_TEAM}`;
  await sql`delete from coderouter_accounts where team_id = ${NATIVE_TEAM}`;
});

afterAll(async () => {
  if (!enabled) return;
  await sql`delete from coderouter_claude_accounts where team_id = ${CLAUDE_TEAM}`;
  await sql`delete from coderouter_accounts where team_id = ${NATIVE_TEAM}`;
  await closeCloudDbForTests();
  await sql.end();
});

async function insertClaudeAccount(): Promise<string> {
  const input = parseClaudeUpstreamInput({
    kind: "anthropic_api_key",
    apiKey: "sk-ant-api03-abcdefghijklmnopqrstuvwxyz0123456789",
    label: "cooldown-test",
  });
  if (!input) throw new Error("invalid Claude fixture");
  return (await claude.add(CLAUDE_TEAM, "cooldown-test-user", input, "team")).id;
}

async function insertNativeAccount(): Promise<string> {
  const [row] = await sql`insert into coderouter_accounts
    (team_id, provider, provider_account_id, label, state)
    values (${NATIVE_TEAM}, 'openai-apikey', 'cooldown-test', 'cooldown-test', 'active')
    returning id`;
  return row!.id as string;
}

dbTest("preserves the longest Claude cooldown and failure reason", async () => {
  const claudeAccountId = await insertClaudeAccount();
  const nativeAccountId = await insertNativeAccount();
  const longClaudeCooldown = new Date(Date.now() + FIVE_HOURS_MS);
  const shortClaudeCooldown = new Date(Date.now() + TWENTY_SECONDS_MS);

  await claudeAccountStore.markCooldown(claudeAccountId, longClaudeCooldown, "rate_limited");
  await claudeAccountStore.markCooldown(claudeAccountId, shortClaudeCooldown, "upstream_unavailable");

  const [claudeAfterShort] = await sql`select cooldown_until, last_failure_code
    from coderouter_claude_accounts where id = ${claudeAccountId}`;
  const storedClaudeCooldown = new Date(String(claudeAfterShort!.cooldown_until)).getTime();
  expect(storedClaudeCooldown).toBeGreaterThanOrEqual(longClaudeCooldown.getTime() - 1_000);
  expect(storedClaudeCooldown).toBeLessThanOrEqual(longClaudeCooldown.getTime());
  expect(claudeAfterShort!.last_failure_code).toBe("rate_limited");

  const longerClaudeCooldown = new Date(longClaudeCooldown.getTime() + ONE_HOUR_MS);
  await claudeAccountStore.markCooldown(claudeAccountId, longerClaudeCooldown, "provider_retry_after");
  const [claudeAfterLong] = await sql`select cooldown_until, last_failure_code
    from coderouter_claude_accounts where id = ${claudeAccountId}`;
  const storedLongerClaudeCooldown = new Date(String(claudeAfterLong!.cooldown_until)).getTime();
  expect(storedLongerClaudeCooldown).toBeGreaterThanOrEqual(longerClaudeCooldown.getTime() - 1_000);
  expect(storedLongerClaudeCooldown).toBeLessThanOrEqual(longerClaudeCooldown.getTime());
  expect(claudeAfterLong!.last_failure_code).toBe("provider_retry_after");

  const nativeLongCooldownFloor = Date.now() + FIVE_HOURS_MS - 1_000;
  await markAccountCooldown(nativeAccountId, FIVE_HOURS_MS, undefined, "rate_limited");
  await markAccountCooldown(nativeAccountId, TWENTY_SECONDS_MS, undefined, "upstream_unavailable");
  const [nativeAfterShort] = await sql`select cooldown_until, last_failure_code
    from coderouter_accounts where id = ${nativeAccountId}`;
  expect(new Date(String(nativeAfterShort!.cooldown_until)).getTime()).toBeGreaterThanOrEqual(nativeLongCooldownFloor);
  expect(nativeAfterShort!.last_failure_code).toBe("rate_limited");
});

const cooldownSequences = [
  {
    name: "rate limit then invalid credential",
    firstDuration: FIVE_HOURS_MS,
    firstReason: "rate_limited",
    secondDuration: FIFTEEN_MINUTES_MS,
    secondReason: "invalid_credential",
    expectedReason: "invalid_credential",
  },
  {
    name: "invalid credential then upstream unavailable",
    firstDuration: FIFTEEN_MINUTES_MS,
    firstReason: "invalid_credential",
    secondDuration: TWENTY_SECONDS_MS,
    secondReason: "upstream_unavailable",
    expectedReason: "invalid_credential",
  },
  {
    name: "rate limit then upstream unavailable",
    firstDuration: FIVE_HOURS_MS,
    firstReason: "rate_limited",
    secondDuration: TWENTY_SECONDS_MS,
    secondReason: "upstream_unavailable",
    expectedReason: "rate_limited",
  },
  {
    name: "upstream unavailable then rate limit",
    firstDuration: TWENTY_SECONDS_MS,
    firstReason: "upstream_unavailable",
    secondDuration: FIVE_HOURS_MS,
    secondReason: "rate_limited",
    expectedReason: "rate_limited",
  },
  {
    name: "invalid credential then longer rate limit",
    firstDuration: FIFTEEN_MINUTES_MS,
    firstReason: "invalid_credential",
    secondDuration: FIVE_HOURS_MS,
    secondReason: "rate_limited",
    expectedReason: "invalid_credential",
  },
];

type StoredCooldown = {
  deadline_ms: string;
  last_failure_code: string | null;
  updated_at: Date;
};

async function readCooldown(pool: "claude" | "native", accountId: string): Promise<StoredCooldown> {
  const rows = pool === "claude"
    ? await sql<StoredCooldown[]>`select round(extract(epoch from cooldown_until) * 1000)::bigint as deadline_ms,
      last_failure_code, updated_at from coderouter_claude_accounts where id = ${accountId}`
    : await sql<StoredCooldown[]>`select round(extract(epoch from cooldown_until) * 1000)::bigint as deadline_ms,
      last_failure_code, updated_at from coderouter_accounts where id = ${accountId}`;
  if (!rows[0]) throw new Error("missing cooldown fixture");
  return rows[0];
}

for (const pool of ["claude", "native"] as const) {
  for (const sequence of cooldownSequences) {
    dbTest(`${pool} cooldown: ${sequence.name}`, async () => {
      const accountId = pool === "claude" ? await insertClaudeAccount() : await insertNativeAccount();
      const startedAt = Date.now();
      if (pool === "claude") {
        await claudeAccountStore.markCooldown(accountId, new Date(startedAt + sequence.firstDuration), sequence.firstReason);
      } else {
        await markAccountCooldown(accountId, sequence.firstDuration, undefined, sequence.firstReason);
      }
      const first = await readCooldown(pool, accountId);
      expect(Number(first.deadline_ms)).toBeGreaterThanOrEqual(startedAt + sequence.firstDuration);
      expect(first.last_failure_code).toBe(sequence.firstReason);

      if (pool === "claude") {
        await sql`update coderouter_claude_accounts set updated_at = '2000-01-01' where id = ${accountId}`;
      } else {
        await sql`update coderouter_accounts set updated_at = '2000-01-01' where id = ${accountId}`;
      }
      const secondStartedAt = Date.now();
      if (pool === "claude") {
        await claudeAccountStore.markCooldown(accountId, new Date(secondStartedAt + sequence.secondDuration), sequence.secondReason);
      } else {
        await markAccountCooldown(accountId, sequence.secondDuration, undefined, sequence.secondReason);
      }
      const after = await readCooldown(pool, accountId);
      const deadline = Number(after.deadline_ms);
      if (sequence.firstDuration > sequence.secondDuration) {
        expect(deadline).toBe(Number(first.deadline_ms));
      } else {
        expect(deadline).toBeGreaterThanOrEqual(secondStartedAt + sequence.secondDuration);
        expect(deadline).toBeLessThanOrEqual(Date.now() + sequence.secondDuration);
      }
      expect(after.last_failure_code).toBe(sequence.expectedReason);
      expect(after.updated_at.getTime()).toBeGreaterThanOrEqual(secondStartedAt);

      if (pool === "claude") {
        const selection = await claude.select(CLAUDE_TEAM, { stickyKey: null });
        expect(selection.kind).toBe("exhausted");
        if (selection.kind !== "exhausted") throw new Error("cooling account was selected");
        if (sequence.expectedReason === "invalid_credential") {
          expect(selection.capacityRetryAfterSeconds).toBeNull();
        } else {
          expect(selection.capacityRetryAfterSeconds).toBeGreaterThan(0);
        }
      } else {
        const capacity = await nextCapacityAvailableAt({ teamId: NATIVE_TEAM, provider: "openai-apikey" });
        if (sequence.expectedReason === "invalid_credential") {
          expect(capacity).toBeNull();
        } else {
          expect(capacity?.getTime()).toBe(deadline);
        }
      }
    });
  }
}


for (const pool of ["claude", "native"] as const) {
  dbTest(`${pool} cooldown replaces an expired non-transient reason`, async () => {
    const accountId = pool === "claude" ? await insertClaudeAccount() : await insertNativeAccount();
    if (pool === "claude") {
      await claudeAccountStore.markCooldown(accountId, new Date(Date.now() + FIFTEEN_MINUTES_MS), "invalid_credential");
      await sql`update coderouter_claude_accounts
        set cooldown_until = '2000-01-01', updated_at = '2000-01-01' where id = ${accountId}`;
    } else {
      await markAccountCooldown(accountId, FIFTEEN_MINUTES_MS, undefined, "invalid_credential");
      await sql`update coderouter_accounts
        set cooldown_until = '2000-01-01', updated_at = '2000-01-01' where id = ${accountId}`;
    }

    const transientStartedAt = Date.now();
    if (pool === "claude") {
      await claudeAccountStore.markCooldown(accountId, new Date(transientStartedAt + TWENTY_SECONDS_MS), "upstream_unavailable");
    } else {
      await markAccountCooldown(accountId, TWENTY_SECONDS_MS, undefined, "upstream_unavailable");
    }
    const row = await readCooldown(pool, accountId);
    expect(row.last_failure_code).toBe("upstream_unavailable");
    expect(Number(row.deadline_ms)).toBeGreaterThanOrEqual(transientStartedAt + TWENTY_SECONDS_MS);

    if (pool === "claude") {
      const selection = await claude.select(CLAUDE_TEAM, { stickyKey: null });
      expect(selection.kind).toBe("exhausted");
      if (selection.kind !== "exhausted") throw new Error("cooling account was selected");
      expect(selection.capacityRetryAfterSeconds).toBeGreaterThan(0);
    } else {
      const capacity = await nextCapacityAvailableAt({ teamId: NATIVE_TEAM, provider: "openai-apikey" });
      expect(capacity?.getTime()).toBeGreaterThanOrEqual(transientStartedAt + TWENTY_SECONDS_MS);
    }
  });

  dbTest(`${pool} cooldown keeps a NULL reason on a live longer deadline`, async () => {
    const accountId = pool === "claude" ? await insertClaudeAccount() : await insertNativeAccount();
    const liveStartedAt = Date.now();
    const liveDuration = ONE_HOUR_MS;
    if (pool === "claude") {
      await sql`update coderouter_claude_accounts
        set cooldown_until = ${new Date(liveStartedAt + liveDuration)}, last_failure_code = null
        where id = ${accountId}`;
      await claudeAccountStore.markCooldown(accountId, new Date(Date.now() + TWENTY_SECONDS_MS), "upstream_unavailable");
    } else {
      await sql`update coderouter_accounts
        set cooldown_until = ${new Date(liveStartedAt + liveDuration)}, last_failure_code = null
        where id = ${accountId}`;
      await markAccountCooldown(accountId, TWENTY_SECONDS_MS, undefined, "upstream_unavailable");
    }
    const row = await readCooldown(pool, accountId);
    expect(row.last_failure_code).toBeNull();
    expect(Number(row.deadline_ms)).toBeGreaterThanOrEqual(liveStartedAt + liveDuration);
  });
}
