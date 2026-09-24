import { afterAll, beforeAll, beforeEach, expect, test } from "bun:test";
import postgres, { type Sql } from "postgres";
import { closeCloudDbForTests } from "../db/client";
import { addAccount } from "../services/coderouter/accounts";
import type { CredentialKeyService } from "../services/coderouter/encryption";
import type { ApiKeyCredential } from "../services/coderouter/types";
import { removeClaudeAccount, updateClaudeAccount } from "../services/coderouter/claudeUpstream";
import { createApiKey, deleteAccount, issueRouteToken } from "../services/coderouter/repository";

// A team member without account administration (#14111) writes only the
// private accounts they imported. These run the real SQL predicates.
const enabled = process.env.CMUX_DB_TEST === "1";
const dbTest = enabled ? test : test.skip;
const TEAM = "member-accounts-team";
const ADMIN = "member-accounts-admin";
const MEMBER = "member-accounts-member";
const OTHER = "member-accounts-other";
const own = { kind: "own-private", userId: MEMBER } as const;
let db: Sql;
const testKeys: CredentialKeyService = {
  async generateDataKey() { return { plaintext: Buffer.alloc(32, 7), encrypted: Buffer.alloc(32, 7) }; },
  async decryptDataKey() { return Buffer.alloc(32, 7); },
};
const noVerify = async () => {};

beforeAll(() => {
  if (!enabled) return;
  db = postgres(process.env.DIRECT_DATABASE_URL ?? process.env.DATABASE_URL!, { max: 3 });
  process.env.CODEROUTER_KMS_KEY_ID = "member-accounts-test-key";
});
afterAll(async () => { await closeCloudDbForTests(); if (db) await db.end(); });
beforeEach(async () => {
  if (!enabled) return;
  await db`delete from coderouter_route_tokens where team_id = ${TEAM}`;
  await db`delete from coderouter_api_keys where team_id = ${TEAM}`;
  await db`delete from coderouter_accounts where team_id = ${TEAM}`;
  await db`delete from coderouter_claude_accounts where team_id = ${TEAM}`;
});

async function nativeAccount(key: string, visibility: "private" | "team", createdBy: string, state = "active") {
  const [row] = await db`insert into coderouter_accounts (team_id, provider, provider_account_id, label, state, visibility, created_by)
    values (${TEAM}, 'openai-apikey', ${key}, ${`${key} label`}, ${state}, ${visibility}, ${createdBy}) returning id`;
  return row.id as string;
}

async function claudeAccount(label: string, visibility: "private" | "team", createdBy: string) {
  const [row] = await db`insert into coderouter_claude_accounts (team_id, kind, label, identifier, visibility, created_by, ciphertext, nonce, auth_tag, encrypted_data_key, kms_key_id)
    values (${TEAM}, 'anthropic_api_key', ${label}, 'masked', ${visibility}, ${createdBy}, 'x', 'x', 'x', 'x', 'x') returning id`;
  return row.id as string;
}

function apiKeyCredential(accountId: string): ApiKeyCredential {
  return { provider: "openai-apikey", apiKey: "sk-test-not-a-real-key", accountId, label: "member label" };
}

async function liveCredentials() {
  const [tokens] = await db`select count(*)::int as count from coderouter_route_tokens where team_id = ${TEAM} and revoked_at is null`;
  const [keys] = await db`select count(*)::int as count from coderouter_api_keys where team_id = ${TEAM} and revoked_at is null`;
  return { routeTokens: tokens.count as number, apiKeys: keys.count as number };
}

dbTest("a member removes their own private account and nothing else", async () => {
  const shared = await nativeAccount("shared", "team", ADMIN);
  const theirs = await nativeAccount("theirs", "private", OTHER);
  const mine = await nativeAccount("mine", "private", MEMBER);

  for (const accountId of [shared, theirs]) {
    await expect(deleteAccount({ teamId: TEAM, accountId, stackUserId: MEMBER, access: own }))
      .resolves.toEqual({ removed: false, lastAccount: false });
  }
  await expect(deleteAccount({ teamId: TEAM, accountId: mine, stackUserId: MEMBER, access: own }))
    .resolves.toEqual({ removed: true, lastAccount: false });
  const rows = await db`select id from coderouter_accounts where team_id = ${TEAM} order by id`;
  expect(rows.map(row => row.id).sort()).toEqual([shared, theirs].sort());
});

dbTest("a member removing the team's last account leaves everyone's tokens and API keys live", async () => {
  const mine = await nativeAccount("mine", "private", MEMBER);
  await issueRouteToken(TEAM, MEMBER);
  await issueRouteToken(TEAM, OTHER);
  await createApiKey(TEAM, ADMIN, "ci");

  await expect(deleteAccount({ teamId: TEAM, accountId: mine, stackUserId: MEMBER, access: own }))
    .resolves.toEqual({ removed: true, lastAccount: true });
  expect(await liveCredentials()).toEqual({ routeTokens: 2, apiKeys: 1 });
});

dbTest("an administrator removing the team's last account still revokes its tokens and API keys", async () => {
  const shared = await nativeAccount("shared", "team", ADMIN);
  await issueRouteToken(TEAM, MEMBER);
  await createApiKey(TEAM, ADMIN, "ci");

  await expect(deleteAccount({ teamId: TEAM, accountId: shared, stackUserId: ADMIN, access: { kind: "user", userId: ADMIN } }))
    .resolves.toEqual({ removed: true, lastAccount: true });
  expect(await liveCredentials()).toEqual({ routeTokens: 0, apiKeys: 0 });
});

dbTest("a member imports a new private account", async () => {
  const result = await addAccount(TEAM, apiKeyCredential("fresh"), testKeys, noVerify, noVerify, {
    createdBy: MEMBER, visibility: "private", access: own,
  });
  expect(result.alreadyExists).toBe(false);
  const [row] = await db`select visibility, created_by from coderouter_accounts where id = ${result.accountId}`;
  expect(row).toEqual({ visibility: "private", created_by: MEMBER });
});

dbTest("a member re-importing a shared account gets it back unchanged", async () => {
  const shared = await nativeAccount("shared", "team", ADMIN);
  await expect(addAccount(TEAM, apiKeyCredential("shared"), testKeys, noVerify, noVerify, {
    createdBy: MEMBER, visibility: "private", access: own,
  })).resolves.toEqual({ accountId: shared, alreadyExists: true });
  const [row] = await db`select label, visibility, created_by, vault_revision from coderouter_accounts where id = ${shared}`;
  expect(row).toEqual({ label: "shared label", visibility: "team", created_by: ADMIN, vault_revision: "1" });
});

dbTest("a member cannot replace the credential of an inactive shared account", async () => {
  const shared = await nativeAccount("shared", "team", ADMIN, "expired");
  await expect(addAccount(TEAM, apiKeyCredential("shared"), testKeys, noVerify, noVerify, {
    createdBy: MEMBER, visibility: "private", access: own,
  })).rejects.toMatchObject({ name: "CoderouterSharedAccountError" });
  const [row] = await db`select state, vault_revision from coderouter_accounts where id = ${shared}`;
  expect(row).toEqual({ state: "expired", vault_revision: "1" });
});

dbTest("a member changes and removes only their own private Claude accounts", async () => {
  const shared = await claudeAccount("Shared", "team", ADMIN);
  const theirs = await claudeAccount("Theirs", "private", OTHER);
  const mine = await claudeAccount("Mine", "private", MEMBER);

  for (const accountId of [shared, theirs]) {
    expect(await updateClaudeAccount(TEAM, accountId, { state: "disabled" }, own)).toBeNull();
    expect(await removeClaudeAccount(TEAM, accountId, own)).toEqual({ removed: false });
  }
  expect(await updateClaudeAccount(TEAM, mine, { label: "Renamed" }, own)).toMatchObject({ id: mine, label: "Renamed" });
  expect(await removeClaudeAccount(TEAM, mine, own)).toEqual({ removed: true });
  const rows = await db`select label, state from coderouter_claude_accounts where team_id = ${TEAM} order by label`;
  expect(rows).toEqual([{ label: "Shared", state: "active" }, { label: "Theirs", state: "active" }]);
});
