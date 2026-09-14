import { afterAll, beforeAll, beforeEach, expect, test } from "bun:test";
import { randomUUID } from "node:crypto";
import postgres, { type Sql } from "postgres";
import { closeCloudDbForTests } from "../db/client";
import { decryptCredential, encryptCredential, type CredentialKeyService } from "../services/coderouter/encryption";
import { claimRefreshLease, CodeRouterCredentialRace, completeRefreshLease, encryptedCredentialForAccount, insertAccountWithCredential, replaceAccountCredential, transferEncryptedAccount } from "../services/coderouter/repository";
import type { CodexCredential } from "../services/coderouter/types";

const enabled = process.env.CMUX_DB_TEST === "1";
const dbTest = enabled ? test : test.skip;
const prefix = `transfer-test-${randomUUID()}`;
const source = `${prefix}-source`;
const destination = `${prefix}-destination`;
const other = `${prefix}-other`;
let sql: Sql;
const keys: CredentialKeyService = {
  async generateDataKey() { return { plaintext: Buffer.alloc(32, 7), encrypted: Buffer.alloc(32, 7) }; },
  async decryptDataKey() { return Buffer.alloc(32, 7); },
};
const idToken = `h.${Buffer.from(JSON.stringify({ email: "transfer@example.test", "https://api.openai.com/auth": { chatgpt_user_id: "provider-user", chatgpt_account_id: "workspace" } })).toString("base64url")}.s`;
const credential: CodexCredential = { provider: "codex", accessToken: "test-access", idToken, refreshToken: "test-refresh", accountId: "workspace", userId: "provider-user", email: "transfer@example.test", expiresAt: Date.now() + 3_600_000 };

beforeAll(() => {
  if (!enabled) return;
  sql = postgres(process.env.DIRECT_DATABASE_URL ?? process.env.DATABASE_URL!, { max: 5 });
  process.env.CODEROUTER_KMS_KEY_ID = "transfer-test-key";
});
async function clean() { await sql`delete from coderouter_accounts where team_id in (${source}, ${destination}, ${other})`; }
beforeEach(async () => { if (enabled) await clean(); });
afterAll(async () => { if (enabled) { await clean(); await closeCloudDbForTests(); await sql.end(); } });

async function create(teamId = source) {
  const accountId = randomUUID();
  const encrypted = await encryptCredential({ accountId, teamId, provider: "codex", credentialRevision: 1, credential, keys });
  expect(await insertAccountWithCredential({ credential, encrypted })).toBe(true);
  return accountId;
}
async function movedEnvelope(accountId: string, teamId = destination) {
  return await encryptCredential({ accountId, teamId, provider: "codex", credentialRevision: 2, credential, keys });
}
async function move(accountId: string, teamId = destination) {
  return await transferEncryptedAccount({ accountId, sourceTeamId: source, destinationTeamId: teamId, stackUserId: "test-user", credential: await movedEnvelope(accountId, teamId) });
}
async function assertOwner(accountId: string, teamId: string, revision: number) {
  const envelope = await encryptedCredentialForAccount(teamId, accountId);
  expect(envelope?.credentialRevision).toBe(revision);
  expect(await decryptCredential(envelope!, keys)).toEqual(credential);
  const [row] = await sql`select team_id, vault_revision from coderouter_accounts where id = ${accountId}`;
  expect(row).toMatchObject({ team_id: teamId, vault_revision: revision });
}

dbTest("a transferred envelope decrypts in its destination with matching revisions", async () => {
  const id = await create();
  expect(await move(id)).toBe(true);
  expect(await encryptedCredentialForAccount(source, id)).toBeNull();
  await assertOwner(id, destination, 2);
});

dbTest("stale transfer snapshots cannot overwrite a newer credential", async () => {
  const id = await create();
  const replacement = await encryptCredential({ accountId: id, teamId: source, provider: "codex", credentialRevision: 2, credential, keys });
  await replaceAccountCredential({ credential, encrypted: replacement, expectedRevision: 1 });
  await expect(move(id)).rejects.toBeInstanceOf(CodeRouterCredentialRace);
  expect(await encryptedCredentialForAccount(destination, id)).toBeNull();
  await assertOwner(id, source, 2);
});

dbTest("a conflicting destination rolls back both account and credential writes", async () => {
  const id = await create();
  await create(destination);
  await expect(move(id)).rejects.toThrow();
  await assertOwner(id, source, 1);
});

dbTest("an active refresh finishes before a transfer can move its credential", async () => {
  const id = await create();
  const leaseId = await claimRefreshLease(id);
  expect(leaseId).not.toBeNull();
  await expect(move(id)).rejects.toBeInstanceOf(CodeRouterCredentialRace);
  await assertOwner(id, source, 1);
  const refreshed = { ...credential, refreshToken: "rotated-refresh" };
  const encrypted = await encryptCredential({ accountId: id, teamId: source, provider: "codex", credentialRevision: 2, credential: refreshed, keys });
  await completeRefreshLease({ accountId: id, leaseId: leaseId!, expectedRevision: 1, credential: refreshed, encrypted });
  const moved = await encryptCredential({ accountId: id, teamId: destination, provider: "codex", credentialRevision: 3, credential: refreshed, keys });
  expect(await transferEncryptedAccount({ accountId: id, sourceTeamId: source, destinationTeamId: destination, stackUserId: "test-user", credential: moved })).toBe(true);
  const envelope = await encryptedCredentialForAccount(destination, id);
  expect(envelope?.credentialRevision).toBe(3);
  expect(await decryptCredential(envelope!, keys)).toEqual(refreshed);
  const [row] = await sql`select state, vault_revision, refresh_lease_id from coderouter_accounts where id = ${id}`;
  expect(row).toMatchObject({ state: "active", vault_revision: 3, refresh_lease_id: null });
});

dbTest("only one concurrent destination can acquire the account", async () => {
  const id = await create();
  const results = await Promise.allSettled([move(id), move(id, other)]);
  expect(results.filter((result) => result.status === "fulfilled")).toHaveLength(1);
  const winner = results[0].status === "fulfilled" ? destination : other;
  await assertOwner(id, winner, 2);
});
