import { afterAll, beforeAll, beforeEach, expect, test } from "bun:test";
import postgres, { type Sql } from "postgres";
import { closeCloudDbForTests } from "../db/client";
import type { CredentialKeyService } from "../services/coderouter/encryption";
import {
  createApiKey,
  listAccounts,
  selectAccountForSession,
} from "../services/coderouter/repository";
import { accountAccessForIdentity } from "../services/coderouter/accountAccess";
import { authenticateCoderouterCredential, authenticateRequestRouteToken } from "../services/coderouter/routeTokenAuth";
import { createCodexResponsesProxy } from "../services/coderouter/codexProxy";
import { createClaudeMessagesProxy } from "../services/coderouter/claudeProxy";
import {
  claudeAccountStore,
  createClaudeUpstreamService,
  parseClaudeUpstreamInput,
} from "../services/coderouter/claudeUpstream";
import { GET as accountsGet } from "../app/api/coderouter/accounts/route";
import { RESPONSES_PROVIDERS } from "../services/coderouter/types";

// https://github.com/manaflow-ai/cmux/issues/14404: a team `crk_` API key
// must not route through its creator's private accounts in an organization.
// Personal scopes (team id = user id) keep their owner's private imports.

const enabled = process.env.CMUX_DB_TEST === "1";
const dbTest = enabled ? test : test.skip;
const ADMIN = "api-key-scope-admin";
const MEMBER = "api-key-scope-member";
const ORG = "api-key-scope-org";
/** The admin's personal scope. */
const PERSONAL = ADMIN;
let db: Sql;

const testKeys: CredentialKeyService = {
  async generateDataKey() { return { plaintext: Buffer.alloc(32, 7), encrypted: Buffer.alloc(32, 7) }; },
  async decryptDataKey() { return Buffer.alloc(32, 7); },
};
const claude = createClaudeUpstreamService({ store: claudeAccountStore, keys: testKeys, keyId: "api-key-scope-test" });

beforeAll(() => {
  if (enabled) db = postgres(process.env.DIRECT_DATABASE_URL ?? process.env.DATABASE_URL!, { max: 3 });
});
afterAll(async () => { await closeCloudDbForTests(); if (db) await db.end(); });
beforeEach(async () => {
  if (!enabled) return;
  for (const team of [ORG, PERSONAL]) {
    await db`delete from coderouter_session_accounts where team_id = ${team}`;
    await db`delete from coderouter_accounts where team_id = ${team}`;
    await db`delete from coderouter_claude_accounts where team_id = ${team}`;
    await db`delete from coderouter_api_keys where team_id = ${team}`;
  }
});

/** A native OpenAI API-key account; its label doubles as the fake secret. */
async function nativeAccount(teamId: string, label: string, visibility: "private" | "team", createdBy: string) {
  const [row] = await db`insert into coderouter_accounts (team_id, provider, provider_account_id, label, state, visibility, created_by)
    values (${teamId}, 'openai-apikey', ${label}, ${label}, 'active', ${visibility}, ${createdBy}) returning id`;
  return row!.id as string;
}

async function claudeAccount(teamId: string, label: string, visibility: "private" | "team", createdBy: string) {
  const input = parseClaudeUpstreamInput({ kind: "anthropic_api_key", apiKey: `sk-ant-api03-${label}-${"x".repeat(24)}`, label });
  if (!input) throw new Error("invalid Claude fixture");
  return (await claude.add(teamId, createdBy, input, visibility)).id;
}

function nativeProxy(upstreamKeys: string[]) {
  return createCodexResponsesProxy({
    authenticate: authenticateCoderouterCredential,
    select: selectAccountForSession,
    credential: async ({ accountId }) => {
      const [row] = await db`select label from coderouter_accounts where id = ${accountId}`;
      return { provider: "openai-apikey", apiKey: `sk-${row!.label as string}`, accountId, label: row!.label as string };
    },
    cooldown: async () => {},
  }, {
    fetch: async (_input, init) => {
      upstreamKeys.push(new Headers(init?.headers).get("authorization") ?? "");
      return new Response("data: done\n\n", { status: 200, headers: { "content-type": "text/event-stream" } });
    },
  });
}

function nativeRequest(key: string, sessionId = "shared-session") {
  return new Request("https://coderouter.test/v1/responses", {
    method: "POST",
    headers: { authorization: `Bearer ${key}`, "content-type": "application/json", session_id: sessionId },
    body: JSON.stringify({ model: "gpt-test", input: [] }),
  });
}

function claudeProxy(upstreamKeys: string[]) {
  return createClaudeMessagesProxy({
    authenticate: (request) => authenticateRequestRouteToken(request),
    select: claude.select,
    cooldown: claude.cooldown,
    touchUsed: claude.touchUsed,
    fetch: (async (_input: string | URL | Request, init?: RequestInit) => {
      upstreamKeys.push(new Headers(init?.headers).get("x-api-key") ?? "");
      return new Response(JSON.stringify({ id: "msg_1", type: "message", usage: { input_tokens: 1, output_tokens: 1 } }), {
        status: 200,
        headers: { "content-type": "application/json" },
      });
    }) as typeof fetch,
    now: () => new Date(),
    capture: () => {},
  });
}

function claudeRequest(key: string) {
  return new Request("https://coderouter.test/v1/messages", {
    method: "POST",
    headers: { "x-api-key": key, "anthropic-version": "2023-06-01", "content-type": "application/json" },
    body: JSON.stringify({ model: "claude-sonnet-4-5", max_tokens: 8, messages: [] }),
  });
}

dbTest("an organization API key cannot select its creator's or a member's private native account", async () => {
  await nativeAccount(ORG, "admin-private", "private", ADMIN);
  await nativeAccount(ORG, "member-private", "private", MEMBER);
  const { key } = await createApiKey(ORG, ADMIN);
  const upstream: string[] = [];
  const proxy = nativeProxy(upstream);

  const refused = await proxy(nativeRequest(key));
  expect(refused.status).toBe(503);
  expect(upstream).toEqual([]);

  await nativeAccount(ORG, "org-shared", "team", MEMBER);
  for (let attempt = 0; attempt < 3; attempt++) {
    expect((await proxy(nativeRequest(key, `session-${attempt}`))).status).toBe(200);
  }
  expect(upstream).toEqual(["Bearer sk-org-shared", "Bearer sk-org-shared", "Bearer sk-org-shared"]);
});

dbTest("an organization API key does not inherit its creator's sticky session on a private account", async () => {
  const adminPrivate = await nativeAccount(ORG, "admin-private", "private", ADMIN);
  // The creator's own `cr login` session pins the session key to the private account.
  const creator = accountAccessForIdentity({ teamId: ORG, stackUserId: ADMIN, vmId: null });
  const pinned = await selectAccountForSession({ teamId: ORG, provider: RESPONSES_PROVIDERS, sessionKey: "same", access: creator });
  expect(pinned?.id).toBe(adminPrivate);
  await nativeAccount(ORG, "org-shared", "team", MEMBER);

  const { key } = await createApiKey(ORG, ADMIN);
  const upstream: string[] = [];
  expect((await nativeProxy(upstream)(nativeRequest(key, "same"))).status).toBe(200);
  expect(upstream).toEqual(["Bearer sk-org-shared"]);
});

dbTest("an organization API key lists only its team's shared accounts", async () => {
  const shared = await nativeAccount(ORG, "org-shared", "team", MEMBER);
  await nativeAccount(ORG, "admin-private", "private", ADMIN);
  const { key } = await createApiKey(ORG, ADMIN);
  const response = await accountsGet(new Request("https://coderouter.test/api/coderouter/accounts", {
    headers: { authorization: `Bearer ${key}` },
  }));
  expect(response.status).toBe(200);
  expect((await response.json()).accounts.map((account: { id: string }) => account.id)).toEqual([shared]);
  const auth = await authenticateRequestRouteToken(new Request("https://coderouter.test/v1/models", {
    headers: { authorization: `Bearer ${key}` },
  }));
  if (!auth.ok) throw new Error("API key did not authenticate");
  expect((await listAccounts(ORG, accountAccessForIdentity(auth.identity))).map((account) => account.id)).toEqual([shared]);
});

dbTest("a personal-team API key still routes through its owner's private native account", async () => {
  await nativeAccount(PERSONAL, "personal-private", "private", ADMIN);
  const { key } = await createApiKey(PERSONAL, ADMIN);
  const upstream: string[] = [];
  expect((await nativeProxy(upstream)(nativeRequest(key))).status).toBe(200);
  expect(upstream).toEqual(["Bearer sk-personal-private"]);
});

dbTest("an organization API key cannot select its creator's or a member's private Claude account", async () => {
  await claudeAccount(ORG, "adminprivate", "private", ADMIN);
  await claudeAccount(ORG, "memberprivate", "private", MEMBER);
  const { key } = await createApiKey(ORG, ADMIN);
  const upstream: string[] = [];
  const proxy = claudeProxy(upstream);

  const refused = await proxy(claudeRequest(key));
  expect(refused.status).toBeGreaterThanOrEqual(400);
  expect(upstream).toEqual([]);

  await claudeAccount(ORG, "orgshared", "team", MEMBER);
  expect((await proxy(claudeRequest(key))).status).toBe(200);
  expect(upstream).toEqual([`sk-ant-api03-orgshared-${"x".repeat(24)}`]);
});

dbTest("a personal-team API key still routes through its owner's private Claude account", async () => {
  await claudeAccount(PERSONAL, "personalprivate", "private", ADMIN);
  const { key } = await createApiKey(PERSONAL, ADMIN);
  const upstream: string[] = [];
  expect((await claudeProxy(upstream)(claudeRequest(key))).status).toBe(200);
  expect(upstream).toEqual([`sk-ant-api03-personalprivate-${"x".repeat(24)}`]);
});

dbTest("the creator's own route token keeps private access in the organization", async () => {
  const adminPrivate = await nativeAccount(ORG, "admin-private", "private", ADMIN);
  const creator = accountAccessForIdentity({ teamId: ORG, stackUserId: ADMIN, vmId: null });
  expect((await listAccounts(ORG, creator)).map((account) => account.id)).toEqual([adminPrivate]);
  expect((await claude.list(ORG, creator))).toEqual([]);
  const claudePrivate = await claudeAccount(ORG, "adminprivate", "private", ADMIN);
  expect((await claude.list(ORG, creator)).map((account) => account.id)).toEqual([claudePrivate]);
});
