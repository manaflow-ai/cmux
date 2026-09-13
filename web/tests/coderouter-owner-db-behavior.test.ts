import { afterAll, beforeAll, beforeEach, expect, test } from "bun:test";
import { randomUUID } from "node:crypto";
import postgres, { type Sql } from "postgres";
import { closeCloudDbForTests } from "../db/client";
import { addAccount } from "../services/coderouter/accounts";
import { bindSessionAccount, findSessionAccount, listAccounts } from "../services/coderouter/repository";
import { encryptCredential, type CredentialKeyService } from "../services/coderouter/encryption";
import type { CodexCredential } from "../services/coderouter/types";

const enabled = process.env.CMUX_DB_TEST === "1";
const dbTest = enabled ? test : test.skip;
const team = "codex-owner-test";
let sql: Sql;
const keys: CredentialKeyService = {
  async generateDataKey() { return { plaintext: Buffer.alloc(32, 7), encrypted: Buffer.alloc(32, 7) }; },
  async decryptDataKey() { return Buffer.alloc(32, 7); },
};
beforeAll(() => {
  if (!enabled) return;
  sql = postgres(process.env.DIRECT_DATABASE_URL ?? process.env.DATABASE_URL!, { max: 5 });
  process.env.CODEROUTER_KMS_KEY_ID = "owner-test-key";
});
beforeEach(async () => { if (enabled) await sql`delete from coderouter_accounts where team_id = ${team}`; });
afterAll(async () => { if (enabled) { await closeCloudDbForTests(); await sql.end(); } });

function credential(user: string, workspace: string, email = "shared@example.com"): CodexCredential {
  const token = `h.${Buffer.from(JSON.stringify({ email, "https://api.openai.com/auth": { chatgpt_user_id: user, chatgpt_account_id: workspace } })).toString("base64url")}.s`;
  return { provider: "codex", accessToken: token, idToken: token, refreshToken: `refresh-${user}`, accountId: workspace, email, expiresAt: Date.now() + 3_600_000 };
}

dbTest("separates users in one workspace and preserves records when email changes", async () => {
  const first = await addAccount(team, credential("user-1", "workspace"), keys);
  const second = await addAccount(team, credential("user-2", "workspace"), keys);
  const personal = await addAccount(team, credential("user-1", "personal"), keys);
  expect(new Set([first.accountId, second.accountId, personal.accountId]).size).toBe(3);
  const renamed = await addAccount(team, credential("user-1", "workspace", "renamed@example.com"), keys);
  expect(renamed).toEqual({ accountId: first.accountId, alreadyExists: true });
  const accounts = await listAccounts(team);
  expect(accounts).toHaveLength(3);
  expect(accounts.find(account => account.id === first.accountId)).toMatchObject({ label: "renamed@example.com", providerUserId: "user-1", providerAccountId: "workspace" });
});

dbTest("concurrent adds create one record for one owner", async () => {
  const results = await Promise.all(Array.from({ length: 6 }, () => addAccount(team, credential("user-1", "workspace"), keys)));
  expect(new Set(results.map(result => result.accountId)).size).toBe(1);
  expect(await listAccounts(team)).toHaveLength(1);
});

dbTest("adopts a legacy workspace row from its encrypted owner without changing session bindings", async () => {
  const id = randomUUID();
  const old = credential("original-user", "workspace");
  const encrypted = await encryptCredential({ teamId: team, accountId: id, provider: "codex", credentialRevision: 1, credential: old, keys });
  await sql`insert into coderouter_accounts (id,team_id,provider,provider_account_id,label,state,vault_revision) values (${id},${team},'codex','workspace','old-email','active',1)`;
  await sql`insert into coderouter_credentials (account_id,team_id,provider,credential_revision,algorithm,ciphertext,nonce,auth_tag,encrypted_data_key,kms_key_id) values (${id},${team},'codex',1,${encrypted.algorithm},${encrypted.ciphertext},${encrypted.nonce},${encrypted.authTag},${encrypted.encryptedDataKey},${encrypted.kmsKeyId})`;
  await bindSessionAccount(team, "codex", "owner-session", id);
  const other = await addAccount(team, credential("new-user", "workspace"), keys);
  expect(other.accountId).not.toBe(id);
  const oldAgain = await addAccount(team, credential("original-user", "workspace", "renamed@example.com"), keys);
  expect(oldAgain.accountId).toBe(id);
  expect((await findSessionAccount(team, "codex", "owner-session", []))?.id).toBe(id);
  expect(await listAccounts(team)).toHaveLength(2);
});
