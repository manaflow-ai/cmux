import { afterAll, beforeAll, beforeEach, expect, test } from "bun:test";
import { randomUUID } from "node:crypto";
import postgres, { type Sql } from "postgres";
import { closeCloudDbForTests } from "../db/client";
import { encryptCredential, decryptCredential, type CredentialKeyService } from "../services/coderouter/encryption";
import { CodeRouterCredentialRace, encryptedCredentialForAccount, transferEncryptedAccount } from "../services/coderouter/repository";
import { parseCredential, transferAccount } from "../services/coderouter/accounts";
import { changeAccountVisibility } from "../services/coderouter/accountSharing";
import { Effect } from "effect";

const enabled = process.env.CMUX_DB_TEST === "1";
const dbTest = enabled ? test : test.skip;
const source = "transfer-test-source";
const destination = "transfer-test-destination";
let db: Sql;
const keys: CredentialKeyService = {
  async generateDataKey() { return { plaintext: Buffer.alloc(32, 7), encrypted: Buffer.alloc(32, 7) }; },
  async decryptDataKey() { return Buffer.alloc(32, 7); },
};
const credential = parseCredential({ provider: "openai-apikey", apiKey: "sk-test-transfer-credential", label: "test" })!;

beforeAll(() => {
  if (enabled) db = postgres(process.env.DIRECT_DATABASE_URL ?? process.env.DATABASE_URL!, { max: 5 });
});
beforeEach(async () => {
  if (enabled) await db`delete from coderouter_accounts where team_id in (${source}, ${destination})`;
});
afterAll(async () => {
  if (enabled) {
    await db`delete from coderouter_accounts where team_id in (${source}, ${destination})`;
    await closeCloudDbForTests();
    await db.end();
  }
});

async function fixture() {
  const accountId = randomUUID();
  const envelope = await encryptCredential({ accountId, teamId: source, provider: credential.provider, credentialRevision: 1, credential, keys, keyId: "test-key" });
  await db`insert into coderouter_accounts (id, team_id, provider, provider_account_id, label, created_by) values (${accountId}, ${source}, ${credential.provider}, 'transfer-provider', 'test', 'transfer-test-user')`;
  await db`insert into coderouter_credentials (account_id, team_id, provider, credential_revision, algorithm, ciphertext, nonce, auth_tag, encrypted_data_key, kms_key_id) values (${accountId}, ${source}, ${credential.provider}, 1, ${envelope.algorithm}, ${envelope.ciphertext}, ${envelope.nonce}, ${envelope.authTag}, ${envelope.encryptedDataKey}, ${envelope.kmsKeyId})`;
  const moved = await encryptCredential({ accountId, teamId: destination, provider: credential.provider, credentialRevision: 2, credential, keys, keyId: "test-key" });
  return { accountId, sourceTeamId: source, destinationTeamId: destination, stackUserId: "transfer-test-user", credential: moved };
}

dbTest("moves a decryptable envelope and its revision together and removes source session bindings", async () => {
  const input = await fixture();
  await db`insert into coderouter_session_accounts (team_id, provider, session_key, account_id) values (${source}, ${credential.provider}, 'session', ${input.accountId})`;
  expect(await transferEncryptedAccount(input)).toBe(true);
  expect(await encryptedCredentialForAccount(source, input.accountId)).toBeNull();
  const stored = await encryptedCredentialForAccount(destination, input.accountId);
  expect(stored?.credentialRevision).toBe(2);
  expect(await decryptCredential(stored!, keys)).toEqual(credential);
  const [account] = await db`select team_id, vault_revision from coderouter_accounts where id = ${input.accountId}`;
  expect(account?.team_id).toBe(destination);
  expect(Number(account?.vault_revision)).toBe(2);
  expect(await db`select * from coderouter_session_accounts where account_id = ${input.accountId}`).toHaveLength(0);
});

dbTest("refuses stale encryption after a concurrent credential revision change", async () => {
  const input = await fixture();
  await db`update coderouter_credentials set credential_revision = 2 where account_id = ${input.accountId}`;
  await db`update coderouter_accounts set vault_revision = 2 where id = ${input.accountId}`;
  await expect(transferEncryptedAccount(input)).rejects.toBeInstanceOf(CodeRouterCredentialRace);
  expect(await encryptedCredentialForAccount(destination, input.accountId)).toBeNull();
  expect((await encryptedCredentialForAccount(source, input.accountId))?.credentialRevision).toBe(2);
});

dbTest("rolls back the envelope move while a refresh lease is active", async () => {
  const input = await fixture();
  await db`update coderouter_accounts set state = 'refreshing', refresh_lease_id = ${randomUUID()}, refresh_lease_expires_at = now() + interval '30 seconds' where id = ${input.accountId}`;
  await expect(transferEncryptedAccount(input)).rejects.toBeInstanceOf(CodeRouterCredentialRace);
  const stored = await encryptedCredentialForAccount(source, input.accountId);
  expect(stored?.credentialRevision).toBe(1);
  expect(await decryptCredential(stored!, keys)).toEqual(credential);
});

dbTest("a duplicate destination identity rolls back both rows", async () => {
  const input = await fixture();
  await db`insert into coderouter_accounts (id, team_id, provider, provider_account_id, label) values (${randomUUID()}, ${destination}, ${credential.provider}, 'transfer-provider', 'existing')`;
  await expect(transferEncryptedAccount(input)).rejects.toThrow();
  const stored = await encryptedCredentialForAccount(source, input.accountId);
  expect(stored?.credentialRevision).toBe(1);
  expect(await decryptCredential(stored!, keys)).toEqual(credential);
});

dbTest("refuses another member's private account before any key operation", async () => {
  const input = await fixture();
  await db`update coderouter_accounts set visibility = 'private', created_by = 'transfer-other-user' where id = ${input.accountId}`;
  let keyOperations = 0;
  const countingKeys: CredentialKeyService = {
    async generateDataKey(request) { keyOperations += 1; return await keys.generateDataKey(request); },
    async decryptDataKey(request) { keyOperations += 1; return await keys.decryptDataKey(request); },
  };
  expect(await transferAccount({
    accountId: input.accountId,
    sourceTeamId: source,
    destinationTeamId: destination,
    stackUserId: "transfer-test-user",
  }, countingKeys)).toBe(false);
  expect(keyOperations).toBe(0);
  const [account] = await db`select team_id from coderouter_accounts where id = ${input.accountId}`;
  expect(account?.team_id).toBe(source);
  expect((await encryptedCredentialForAccount(source, input.accountId))?.credentialRevision).toBe(1);
});

dbTest("no member can claim an ownerless legacy shared account through sharing", async () => {
  const input = await fixture();
  await db`update coderouter_accounts set visibility = 'team', created_by = null where id = ${input.accountId}`;
  for (const visibility of ["private", "team"] as const) {
    const result = await Effect.runPromise(changeAccountVisibility({
      teamId: source, userId: "transfer-test-user", accountId: input.accountId, family: "native", visibility,
    }));
    expect(result).toBeNull();
  }
  const [account] = await db`select visibility, created_by from coderouter_accounts where id = ${input.accountId}`;
  expect(account).toEqual({ visibility: "team", created_by: null });
});

dbTest("the importer still changes their own account's sharing", async () => {
  const input = await fixture();
  const result = await Effect.runPromise(changeAccountVisibility({
    teamId: source, userId: "transfer-test-user", accountId: input.accountId, family: "native", visibility: "private",
  }));
  expect(result).toEqual({ id: input.accountId, visibility: "private" });
});
