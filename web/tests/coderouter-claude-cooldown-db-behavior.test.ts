import { afterAll, beforeAll, beforeEach, expect, test } from "bun:test";
import postgres, { type Sql } from "postgres";
import { closeCloudDbForTests } from "../db/client";
import { markAccountCooldown } from "../services/coderouter/repository";
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
  expect(new Date(String(claudeAfterShort!.cooldown_until)).getTime()).toBe(longClaudeCooldown.getTime());
  expect(claudeAfterShort!.last_failure_code).toBe("rate_limited");

  const longerClaudeCooldown = new Date(longClaudeCooldown.getTime() + ONE_HOUR_MS);
  await claudeAccountStore.markCooldown(claudeAccountId, longerClaudeCooldown, "provider_retry_after");
  const [claudeAfterLong] = await sql`select cooldown_until, last_failure_code
    from coderouter_claude_accounts where id = ${claudeAccountId}`;
  expect(new Date(String(claudeAfterLong!.cooldown_until)).getTime()).toBe(longerClaudeCooldown.getTime());
  expect(claudeAfterLong!.last_failure_code).toBe("provider_retry_after");

  const nativeLongCooldownFloor = Date.now() + FIVE_HOURS_MS - 1_000;
  await markAccountCooldown(nativeAccountId, FIVE_HOURS_MS, undefined, "rate_limited");
  await markAccountCooldown(nativeAccountId, TWENTY_SECONDS_MS, undefined, "upstream_unavailable");
  const [nativeAfterShort] = await sql`select cooldown_until, last_failure_code
    from coderouter_accounts where id = ${nativeAccountId}`;
  expect(new Date(String(nativeAfterShort!.cooldown_until)).getTime()).toBeGreaterThanOrEqual(nativeLongCooldownFloor);
});
