import { grantVmImportedAccount } from "../services/coderouter/vmAccountImport";
import { afterAll, beforeAll, beforeEach, expect, test } from "bun:test";
import { Effect } from "effect";
import { changeAccountVisibility } from "../services/coderouter/accountSharing";
import { randomUUID } from "node:crypto";
import postgres, { type Sql } from "postgres";
import { cloudDb, closeCloudDbForTests } from "../db/client";
import { addAccount } from "../services/coderouter/accounts";
import { encryptCredential, type CredentialKeyService } from "../services/coderouter/encryption";
import type { CodexCredential } from "../services/coderouter/types";
import { authenticateRequestRouteToken } from "../services/coderouter/routeTokenAuth";
import "./vm-authorization-fixture";
import { authenticateRouteToken, deleteAccount, issueRouteToken, issueVmAuthorizationToken, listAccounts, selectAccountForRequest, selectAccountForSession } from "../services/coderouter/repository";
import { listClaudeAccounts } from "../services/coderouter/claudeUpstream";
import { resolveCoderouterUsageTeam, resolveCodeRouterRequestContext, resolveCoderouterControlContext } from "../services/coderouter/requestContext";
import { GET as accountsGet } from "../app/api/coderouter/accounts/route";
import { GET as claudeGet } from "../app/api/coderouter/claude-upstream/route";
import { GET as organizationsGet } from "../app/api/coderouter/organizations/route";

const enabled = process.env.CMUX_DB_TEST === "1";
const dbTest = enabled ? test : test.skip;
const USER = "vm-scope-test-user";
const TEAM_A = "vm-scope-team-a";
const TEAM_B = "vm-scope-team-b";
let db: Sql;
let vmA: string;
let vmB: string;
let poolA: string;
let poolB: string;
let sharedA: string;
let privateA: string;
let sharedB: string;
let claudeA: string;
let tokenA: string;
const testKeys: CredentialKeyService = {
  async generateDataKey() { return { plaintext: Buffer.alloc(32, 9), encrypted: Buffer.alloc(32, 9) }; },
  async decryptDataKey() { return Buffer.alloc(32, 9); },
};

beforeAll(() => {
  if (enabled) db = postgres(process.env.DIRECT_DATABASE_URL ?? process.env.DATABASE_URL!, { max: 3 });
});
afterAll(async () => { await closeCloudDbForTests(); if (db) await db.end(); });
beforeEach(async () => {
  if (!enabled) return;
  await db`delete from coderouter_route_tokens where team_id in (${TEAM_A}, ${TEAM_B}, ${USER})`;
  await db`delete from cloud_vms where user_id = ${USER}`;
  await db`delete from coderouter_accounts where team_id in (${TEAM_A}, ${TEAM_B}, ${USER})`;
  await db`delete from coderouter_claude_accounts where team_id in (${TEAM_A}, ${TEAM_B}, ${USER})`;
  await db`delete from coderouter_pools where team_id in (${TEAM_A}, ${TEAM_B}, ${USER})`;
  const vms = await db`insert into cloud_vms (user_id, billing_team_id, provider, provider_vm_id, image_id, status)
    values (${USER}, ${TEAM_A}, 'freestyle', ${randomUUID()}, 'test', 'running'),
           (${USER}, ${TEAM_B}, 'freestyle', ${randomUUID()}, 'test', 'running') returning id, owner_team_id, coderouter_pool_id`;
  const a = vms.find(row => row.owner_team_id === TEAM_A)!;
  const b = vms.find(row => row.owner_team_id === TEAM_B)!;
  vmA = a.id; vmB = b.id; poolA = a.coderouter_pool_id; poolB = b.coderouter_pool_id;
  const accounts = await db`insert into coderouter_accounts (team_id, provider, provider_account_id, label, visibility, created_by)
    values (${TEAM_A}, 'openai-apikey', 'a-shared', 'Team A shared', 'team', ${USER}),
           (${TEAM_A}, 'openai-apikey', 'a-private', 'Team A private', 'private', ${USER}),
           (${TEAM_B}, 'openai-apikey', 'b-shared', 'Team B shared', 'team', ${USER}) returning id, provider_account_id`;
  sharedA = accounts.find(row => row.provider_account_id === 'a-shared')!.id;
  privateA = accounts.find(row => row.provider_account_id === 'a-private')!.id;
  sharedB = accounts.find(row => row.provider_account_id === 'b-shared')!.id;
  const claude = await db`insert into coderouter_claude_accounts (team_id, kind, label, identifier, visibility, created_by, ciphertext, nonce, auth_tag, encrypted_data_key, kms_key_id)
    values (${TEAM_A}, 'anthropic_api_key', 'Claude A shared', 'masked-a', 'team', ${USER}, 'x', 'x', 'x', 'x', 'x'),
           (${TEAM_A}, 'anthropic_api_key', 'Claude A private', 'masked-private', 'private', ${USER}, 'x', 'x', 'x', 'x', 'x'),
           (${TEAM_B}, 'anthropic_api_key', 'Claude B shared', 'masked-b', 'team', ${USER}, 'x', 'x', 'x', 'x', 'x') returning id, label`;
  claudeA = claude.find(row => row.label === 'Claude A shared')!.id;
  tokenA = (await issueRouteToken(TEAM_A, USER, 'vm', { vmId: vmA })).token;
});
function guest(path: string, headers: Record<string, string> = {}) {
  return new Request(`https://coderouter.test${path}`, { headers: {
    "x-coderouter-route-token": tokenA, "x-cmux-vm-id": vmA,
    authorization: "Bearer cmux-vm-edge-placeholder", ...headers,
  } });
}
function access() { return { kind: "vm" as const, vmId: vmA, poolId: poolA }; }
function codexCredential(userId: string, accountId: string): CodexCredential {
  const token = `h.${Buffer.from(JSON.stringify({ email: "vm@example.com", "https://api.openai.com/auth": { chatgpt_user_id: userId, chatgpt_account_id: accountId } })).toString("base64url")}.s`;
  return {
    provider: "codex",
    accessToken: token,
    refreshToken: `refresh-${userId}`,
    idToken: token,
    accountId,
    email: "vm@example.com",
    expiresAt: Date.now() + 3_600_000,
  };
}

async function insertLegacyCodexAccount(credential: CodexCredential, visibility: "private" | "team" = "team") {
  const id = randomUUID();
  const encrypted = await encryptCredential({
    teamId: TEAM_A,
    accountId: id,
    provider: "codex",
    credentialRevision: 1,
    credential,
    keyId: "vm-scope-test-key",
    keys: testKeys,
  });
  await db`insert into coderouter_accounts (id, team_id, provider, provider_account_id, label, state, vault_revision, visibility, created_by)
    values (${id}, ${TEAM_A}, 'codex', ${credential.accountId}, 'legacy', 'active', 1, ${visibility}, ${visibility === "team" ? USER : "another-user"})`;
  await db`insert into coderouter_credentials (account_id, team_id, provider, credential_revision, algorithm, ciphertext, nonce, auth_tag, encrypted_data_key, kms_key_id)
    values (${id}, ${TEAM_A}, 'codex', 1, ${encrypted.algorithm}, ${encrypted.ciphertext}, ${encrypted.nonce}, ${encrypted.authTag}, ${encrypted.encryptedDataKey}, ${encrypted.kmsKeyId})`;
  return id;
}

dbTest("VM list APIs ignore team overrides and hide private and foreign accounts", async () => {
  const request = guest('/api/coderouter/accounts?teamId='+TEAM_B, { 'x-cmux-team-id': TEAM_B });
  const resolved = await resolveCoderouterUsageTeam(request);
  expect(resolved).toMatchObject({ ok: true, teamId: TEAM_A, vmId: vmA, access: access() });
  const response = await accountsGet(request);
  expect(response.status).toBe(200);
  const body = await response.json();
  expect(body.teamId).toBe(TEAM_A);
  expect(body.accounts.map((account: {id: string}) => account.id)).toEqual([sharedA]);
  const claude = await claudeGet(guest('/api/coderouter/claude-upstream', { 'x-cmux-team-id': TEAM_B }));
  expect(claude.status).toBe(200);
  expect((await claude.json()).accounts.map((account: {id: string}) => account.id)).toEqual([claudeA]);
});

dbTest("same creator cannot authorize another team's VM", async () => {
  const wrong = await issueRouteToken(TEAM_A, USER, 'vm', { vmId: vmB });
  expect(await authenticateRouteToken(wrong.token)).toBeNull();
  const identity = await authenticateRequestRouteToken(guest('/v1/models'));
  expect(identity).toMatchObject({ ok: true, identity: { teamId: TEAM_A, vmId: vmA, poolId: poolA } });
  expect(await authenticateRequestRouteToken(guest('/v1/models', { 'x-cmux-vm-id': vmB }))).toMatchObject({ ok: false });
  expect(await resolveCoderouterUsageTeam(guest('/api/coderouter/accounts', { 'x-cmux-vm-id': vmB }))).toMatchObject({ ok: false });
});

dbTest("a signed VM authorization authenticates against the live VM row", async () => {
  // cloud_vms.id is uuid and coderouter_route_tokens.vm_id is text; the
  // lookup must not compare the two columns directly.
  const signed = await issueVmAuthorizationToken(TEAM_A, USER, vmA);
  expect(await authenticateRouteToken(signed.token)).toEqual({ teamId: TEAM_A, stackUserId: USER, vmId: vmA, poolId: poolA });
  const request = new Request("https://coderouter.test/v1/models", { headers: { "x-cmux-authorization": `Bearer ${signed.token}` } });
  expect(await authenticateRequestRouteToken(request)).toMatchObject({ ok: true, identity: { teamId: TEAM_A, vmId: vmA, poolId: poolA } });
  await db`update cloud_vms set status = 'destroyed' where id = ${vmA}`;
  expect(await authenticateRouteToken(signed.token)).toBeNull();
});

dbTest("pool membership and account visibility constrain selection and cached sessions", async () => {
  const first = await selectAccountForSession({ teamId: TEAM_A, provider: 'openai-apikey', sessionKey: 'same-session', access: access() });
  expect(first?.id).toBe(sharedA);
  await db`delete from coderouter_pool_accounts where pool_id = ${poolA}`;
  expect(await selectAccountForSession({ teamId: TEAM_A, provider: 'openai-apikey', sessionKey: 'same-session', access: access() })).toBeNull();
  expect(await listAccounts(TEAM_A, access())).toEqual([]);
  // Even a same-team but erroneous private grant cannot override visibility.
  await db`insert into coderouter_pool_accounts (team_id, pool_id, account_id) values (${TEAM_A}, ${poolA}, ${privateA})`;
  expect(await selectAccountForRequest(TEAM_A, 'openai-apikey', [], undefined, access())).toBeNull();
});

dbTest("database refuses cross-team grants, pools, and owner reassignment", async () => {
  await expect(Promise.resolve(db`insert into coderouter_pool_accounts (team_id, pool_id, account_id) values (${TEAM_A}, ${poolA}, ${sharedB})`)).rejects.toThrow();
  await expect(Promise.resolve(db`update cloud_vms set coderouter_pool_id = ${poolB} where id = ${vmA}`)).rejects.toThrow();
  await expect(Promise.resolve(db`update cloud_vms set owner_team_id = ${TEAM_B} where id = ${vmA}`)).rejects.toThrow();
  await db`update cloud_vms set billing_team_id = ${TEAM_B} where id = ${vmA}`;
  expect(await authenticateRouteToken(tokenA)).toMatchObject({ teamId: TEAM_A, vmId: vmA });
});

dbTest("VM organization catalog is fixed and VM credentials cannot administer accounts", async () => {
  const response = await organizationsGet(guest('/api/coderouter/organizations', { 'x-cmux-team-id': TEAM_B }));
  expect(await response.json()).toMatchObject({ fixed: true, selectedTeamId: TEAM_A, teams: [{ id: TEAM_A, permissions: { manageAccounts: false } }] });
  const resolved = await resolveCodeRouterRequestContext(guest('/api/coderouter/session', { 'x-cmux-team-id': TEAM_B }));
  expect(resolved.ok).toBe(false);
  if (!resolved.ok) expect(resolved.response.status).toBe(403);
});

dbTest("private imports are visible to their user but never inherited by their team VM", async () => {
  expect((await listAccounts(TEAM_A, { kind: 'user', userId: USER })).map(a => a.id).sort()).toEqual([sharedA, privateA].sort());
  expect((await listAccounts(TEAM_A, { kind: 'user', userId: 'other-user' })).map(a => a.id)).toEqual([sharedA]);
  await db`update coderouter_accounts set visibility = 'team' where id = ${privateA}`;
  expect((await listAccounts(TEAM_A, access())).map(a => a.id).sort()).toEqual([sharedA, privateA].sort());
  await db`update coderouter_accounts set visibility = 'private' where id = ${privateA}`;
  expect((await listAccounts(TEAM_A, access())).map(a => a.id)).toEqual([sharedA]);
  expect((await listClaudeAccounts(TEAM_A, access())).map(a => a.id)).toEqual([claudeA]);
});

dbTest("destroying a VM invalidates its credential without waiting for token expiry", async () => {
  await db`update cloud_vms set status = 'destroyed' where id = ${vmA}`;
  expect(await authenticateRouteToken(tokenA)).toBeNull();
  const response = await accountsGet(guest('/api/coderouter/accounts'));
  expect(response.status).toBe(401);
});


dbTest("sharing requires the importer even when the account is currently shared", async () => {
  for (const accountId of [sharedA, privateA]) {
    const result = await Effect.runPromise(changeAccountVisibility({ teamId: TEAM_A, userId: 'another-admin',
      accountId, family: 'native', visibility: 'private' }));
    expect(result).toBeNull();
  }
  const changed = await Effect.runPromise(changeAccountVisibility({ teamId: TEAM_A, userId: USER,
    accountId: privateA, family: 'native', visibility: 'team' }));
  expect(changed).toEqual({ id: privateA, visibility: 'team' });
  expect((await listAccounts(TEAM_A, access())).map(a => a.id).sort()).toEqual([sharedA, privateA].sort());
});

dbTest("older account writers preserve shared access during deployment", async () => {
  const [old] = await db`insert into coderouter_accounts (team_id, provider, provider_account_id, label)
    values (${TEAM_A}, 'openai-apikey', 'legacy-writer', 'Legacy import') returning id, visibility`;
  expect(old.visibility).toBe('team');
  expect((await listAccounts(TEAM_A, access())).map(a => a.id)).toContain(old.id);
});


dbTest("personal VMs can use their owner's private pool without granting organization access", async () => {
  const [personalVm] = await db`insert into cloud_vms (user_id, billing_team_id, provider, image_id, status)
    values (${USER}, ${USER}, 'freestyle', 'test', 'running') returning id, coderouter_pool_id`;
  const [personalAccount] = await db`insert into coderouter_accounts (team_id, provider, provider_account_id, label, visibility, created_by)
    values (${USER}, 'openai-apikey', 'personal', 'Personal', 'private', ${USER}) returning id`;
  const personal = { kind: 'vm' as const, vmId: personalVm.id as string, poolId: personalVm.coderouter_pool_id as string };
  expect((await listAccounts(USER, personal)).map(a => a.id)).toEqual([personalAccount.id]);
  expect((await selectAccountForRequest(USER, 'openai-apikey', [], undefined, personal))?.id).toBe(personalAccount.id);
  expect(await listAccounts(USER, access())).toEqual([]);
  expect(await listAccounts(USER, { ...personal, vmId: vmA })).toEqual([]);
  expect(await listAccounts(USER, { kind: 'user', userId: 'other-person' })).toEqual([]);
});


dbTest("VM account mutations retain the pool boundary and cannot borrow the creator's private access", async () => {
  const resolved = await resolveCoderouterControlContext(guest('/api/coderouter/accounts', {'x-cmux-team-id': TEAM_B}));
  expect(resolved).toMatchObject({ok:true,value:{team:{teamId:TEAM_A},access:access()}});
  for (const accountId of [privateA, sharedB]) {
    expect(await deleteAccount({teamId:TEAM_A,stackUserId:USER,accountId,access:access()})).toMatchObject({removed:false});
  }
  await db`delete from coderouter_pool_accounts where pool_id = ${poolA} and account_id = ${sharedA}`;
  expect(await deleteAccount({teamId:TEAM_A,stackUserId:USER,accountId:sharedA,access:access()})).toMatchObject({removed:false});
  await db`insert into coderouter_pool_accounts (team_id,pool_id,account_id) values (${TEAM_A},${poolA},${sharedA})`;
  expect(await deleteAccount({teamId:TEAM_A,accountId:sharedA,access:access()})).toMatchObject({removed:true});
});

dbTest("a VM import is granted to its current custom pool and rejects stale or foreign bindings", async () => {
  const [custom] = await db`insert into coderouter_pools (team_id,name) values (${TEAM_A},'Import pool') returning id`;
  await db`update cloud_vms set coderouter_pool_id = ${custom.id} where id = ${vmA}`;
  const scope = {kind:'vm' as const,vmId:vmA,poolId:custom.id as string};
  expect(await listAccounts(TEAM_A,scope)).toEqual([]);
  await cloudDb().transaction(tx=>grantVmImportedAccount(tx,TEAM_A,sharedA,'native',scope));
  expect((await listAccounts(TEAM_A,scope)).map(a=>a.id)).toEqual([sharedA]);
  await expect(cloudDb().transaction(tx=>grantVmImportedAccount(tx,TEAM_B,sharedB,'native',scope))).rejects.toThrow();
  await expect(cloudDb().transaction(tx=>grantVmImportedAccount(tx,TEAM_A,sharedA,'native',access()))).rejects.toThrow();
});

dbTest("VM Codex imports migrate visible legacy rows and reject hidden duplicates", async () => {
  const visibleCredential = codexCredential("legacy-visible-user", "legacy-visible-workspace");
  const visibleId = await insertLegacyCodexAccount(visibleCredential);

  const visibleResult = await addAccount(
    TEAM_A,
    visibleCredential,
    testKeys,
    async () => {},
    async () => {},
    { createdBy: USER, visibility: "team", access: access() },
  );
  expect(visibleResult).toEqual({ accountId: visibleId, alreadyExists: true });
  const [migrated] = await db`select provider_account_id from coderouter_accounts where id = ${visibleId}`;
  expect(migrated.provider_account_id).not.toBe(visibleCredential.accountId);

  const hiddenCredential = codexCredential("legacy-hidden-user", "legacy-hidden-workspace");
  await insertLegacyCodexAccount(hiddenCredential, "private");
  await expect(addAccount(
    TEAM_A,
    hiddenCredential,
    testKeys,
    async () => {},
    async () => {},
    { createdBy: USER, visibility: "team", access: access() },
  )).rejects.toThrow("outside this VM's account pool");
  const [{ count }] = await db`select count(*)::int as count from coderouter_accounts where team_id = ${TEAM_A} and provider = 'codex'`;
  expect(count).toBe(2);
});
