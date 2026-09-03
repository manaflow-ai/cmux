import { beforeEach, describe, expect, mock, test } from "bun:test";
import { randomBytes } from "node:crypto";
import {
  createClaudeUpstreamService,
  parseClaudeUpstreamInput,
  type ClaudeUpstreamRow,
  type ClaudeUpstreamStore,
} from "../services/coderouter/claudeUpstream";
import type { CredentialKeyService } from "../services/coderouter/encryption";
import { makeClaudeUpstreamHandlers } from "../app/api/coderouter/claude-upstream/route";

const API_KEY = "sk-ant-api03-abcdefghijklmnopqrstuvwxyz0123456789";
const OAUTH_TOKEN = "sk-ant-oat01-abcdefghijklmnopqrstuvwxyz0123456789-ABCDEF";
const ACCESS_KEY_ID = "AKIAIOSFODNN7EXAMPLE";
const SECRET_ACCESS_KEY = "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY";

function fakeKeys(): CredentialKeyService {
  const dataKey = randomBytes(32);
  return {
    async generateDataKey() {
      return { plaintext: Buffer.from(dataKey), encrypted: Buffer.from(dataKey) };
    },
    async decryptDataKey({ encrypted }) {
      if (!Buffer.from(encrypted).equals(dataKey)) throw new Error("wrong test key");
      return Buffer.from(dataKey);
    },
  };
}

function memoryStore(): ClaudeUpstreamStore & { rows: Map<string, ClaudeUpstreamRow> } {
  const rows = new Map<string, ClaudeUpstreamRow>();
  return {
    rows,
    async read(teamId) {
      return rows.get(teamId) ?? null;
    },
    async write(row) {
      const written = { ...row, updatedAt: new Date("2026-09-02T10:00:00.000Z") };
      rows.set(row.teamId, written);
      return written;
    },
    async remove(teamId) {
      return rows.delete(teamId);
    },
  };
}

describe("claude upstream input validation", () => {
  test("accepts an Anthropic API key and rejects OAuth tokens in its place", () => {
    expect(parseClaudeUpstreamInput({ kind: "anthropic_api_key", apiKey: ` ${API_KEY} ` })).toEqual({
      kind: "anthropic_api_key",
      apiKey: API_KEY,
    });
    expect(parseClaudeUpstreamInput({ kind: "anthropic_api_key", apiKey: OAUTH_TOKEN })).toBeNull();
    expect(parseClaudeUpstreamInput({ kind: "anthropic_api_key", apiKey: "sk-live-nope" })).toBeNull();
    expect(parseClaudeUpstreamInput({ kind: "anthropic_api_key", apiKey: "sk-ant-short" })).toBeNull();
  });

  test("accepts a Claude Code OAuth token only with its prefix", () => {
    expect(parseClaudeUpstreamInput({ kind: "anthropic_oauth", token: OAUTH_TOKEN })).toEqual({
      kind: "anthropic_oauth",
      token: OAUTH_TOKEN,
    });
    expect(parseClaudeUpstreamInput({ kind: "anthropic_oauth", token: API_KEY })).toBeNull();
  });

  test("validates Bedrock region, keys, session token and model overrides", () => {
    const base = {
      kind: "bedrock",
      region: "us-east-1",
      accessKeyId: ACCESS_KEY_ID,
      secretAccessKey: SECRET_ACCESS_KEY,
    };
    expect(parseClaudeUpstreamInput(base)).toEqual(base);
    expect(parseClaudeUpstreamInput({ ...base, sessionToken: "" })).toEqual(base);
    expect(parseClaudeUpstreamInput({ ...base, sessionToken: "FwoGZXIvYXdzEBYaDExampleSession" })).toEqual({
      ...base,
      sessionToken: "FwoGZXIvYXdzEBYaDExampleSession",
    });
    expect(parseClaudeUpstreamInput({ ...base, region: "US-EAST-1" })).toBeNull();
    expect(parseClaudeUpstreamInput({ ...base, region: "us-east" })).toBeNull();
    expect(parseClaudeUpstreamInput({ ...base, region: "ap-southeast-2" })).toMatchObject({ region: "ap-southeast-2" });
    expect(parseClaudeUpstreamInput({ ...base, accessKeyId: "notakey" })).toBeNull();
    expect(parseClaudeUpstreamInput({ ...base, secretAccessKey: "short" })).toBeNull();
    expect(parseClaudeUpstreamInput({ ...base, sessionToken: "bad token!" })).toBeNull();
    expect(
      parseClaudeUpstreamInput({ ...base, modelIds: { "claude-sonnet-4-5": "us.anthropic.claude-sonnet-4-5-20250929-v1:0" } }),
    ).toEqual({ ...base, modelIds: { "claude-sonnet-4-5": "us.anthropic.claude-sonnet-4-5-20250929-v1:0" } });
    expect(parseClaudeUpstreamInput({ ...base, modelIds: { "claude-sonnet-4-5": "gpt-5" } })).toBeNull();
    expect(parseClaudeUpstreamInput({ ...base, modelIds: { "../etc": "anthropic.claude-x" } })).toBeNull();
  });

  test("rejects unknown kinds and non-objects", () => {
    expect(parseClaudeUpstreamInput({ kind: "openai", apiKey: API_KEY })).toBeNull();
    expect(parseClaudeUpstreamInput("sk-ant")).toBeNull();
    expect(parseClaudeUpstreamInput(null)).toBeNull();
  });
});

describe("claude upstream service", () => {
  test("stores an encrypted secret and describes it without leaking", async () => {
    const store = memoryStore();
    const service = createClaudeUpstreamService({ store, keys: fakeKeys(), keyId: "kms-test" });
    const described = await service.put("team-1", "user-1", { kind: "anthropic_api_key", apiKey: API_KEY });
    expect(described).toEqual({
      kind: "anthropic_api_key",
      identifier: "sk-ant-...6789",
      region: null,
      modelIds: {},
      updatedAt: "2026-09-02T10:00:00.000Z",
    });
    expect(JSON.stringify(described)).not.toContain(API_KEY);
    const row = store.rows.get("team-1")!;
    expect(JSON.stringify(row)).not.toContain(API_KEY);
    expect(row.kmsKeyId).toBe("kms-test");
    expect(row.updatedBy).toBe("user-1");
    expect(row.config).toEqual({});

    const decrypted = await service.get("team-1");
    expect(decrypted?.secret).toEqual({ kind: "anthropic_api_key", apiKey: API_KEY });
    expect(await service.describe("team-1")).toEqual(described);
  });

  test("keeps Bedrock region and overrides out of the ciphertext", async () => {
    const store = memoryStore();
    const service = createClaudeUpstreamService({ store, keys: fakeKeys(), keyId: "kms-test" });
    const described = await service.put("team-1", "user-1", {
      kind: "bedrock",
      region: "us-west-2",
      accessKeyId: ACCESS_KEY_ID,
      secretAccessKey: SECRET_ACCESS_KEY,
      sessionToken: "FwoGZXIvYXdzEBYaDExampleSession",
      modelIds: { "claude-sonnet-4-5": "us.anthropic.claude-sonnet-4-5-20250929-v1:0" },
    });
    expect(described).toMatchObject({
      kind: "bedrock",
      identifier: "AKIA...MPLE",
      region: "us-west-2",
      modelIds: { "claude-sonnet-4-5": "us.anthropic.claude-sonnet-4-5-20250929-v1:0" },
    });
    const row = store.rows.get("team-1")!;
    expect(row.config).toEqual({
      region: "us-west-2",
      modelIds: { "claude-sonnet-4-5": "us.anthropic.claude-sonnet-4-5-20250929-v1:0" },
    });
    const serialized = JSON.stringify(row);
    expect(serialized).not.toContain(SECRET_ACCESS_KEY);
    expect(serialized).not.toContain("FwoGZXIvYXdzEBYaDExampleSession");
    expect(serialized).not.toContain(ACCESS_KEY_ID);
    const decrypted = await service.get("team-1");
    expect(decrypted?.secret).toEqual({
      kind: "bedrock",
      accessKeyId: ACCESS_KEY_ID,
      secretAccessKey: SECRET_ACCESS_KEY,
      sessionToken: "FwoGZXIvYXdzEBYaDExampleSession",
    });
    expect(decrypted?.config).toEqual({
      region: "us-west-2",
      modelIds: { "claude-sonnet-4-5": "us.anthropic.claude-sonnet-4-5-20250929-v1:0" },
    });
  });

  test("replaces the single upstream and removes it", async () => {
    const store = memoryStore();
    const service = createClaudeUpstreamService({ store, keys: fakeKeys(), keyId: "kms-test" });
    await service.put("team-1", "user-1", { kind: "anthropic_api_key", apiKey: API_KEY });
    const replaced = await service.put("team-1", "user-2", { kind: "anthropic_oauth", token: OAUTH_TOKEN });
    expect(replaced.kind).toBe("anthropic_oauth");
    expect(replaced.identifier).toBe("sk-ant-oat01-...CDEF");
    expect(store.rows.size).toBe(1);
    expect((await service.get("team-1"))?.secret).toEqual({ kind: "anthropic_oauth", token: OAUTH_TOKEN });
    expect(await service.remove("team-1")).toEqual({ removed: true });
    expect(await service.remove("team-1")).toEqual({ removed: false });
    expect(await service.describe("team-1")).toBeNull();
  });

  test("binds the ciphertext to the team and kind", async () => {
    const store = memoryStore();
    const keys = fakeKeys();
    const service = createClaudeUpstreamService({ store, keys, keyId: "kms-test" });
    await service.put("team-1", "user-1", { kind: "anthropic_api_key", apiKey: API_KEY });
    const row = store.rows.get("team-1")!;
    store.rows.set("team-2", { ...row, teamId: "team-2" });
    await expect(service.get("team-2")).rejects.toThrow();
    store.rows.set("team-1", { ...row, kind: "anthropic_oauth" });
    await expect(service.get("team-1")).rejects.toThrow();
  });
});

describe("claude upstream route", () => {
  const context = {
    ok: true as const,
    value: {
      user: { id: "user_1" },
      team: { teamId: "team_1", teamName: "Team", use: true, manageAccounts: true },
    },
  };
  const forbidden = {
    ok: false as const,
    response: Response.json({ error: "forbidden" }, { status: 403 }),
  };
  let store: ReturnType<typeof memoryStore>;
  let service: ReturnType<typeof createClaudeUpstreamService>;

  beforeEach(() => {
    store = memoryStore();
    service = createClaudeUpstreamService({ store, keys: fakeKeys(), keyId: "kms-test" });
  });

  function handlers(overrides: Partial<Parameters<typeof makeClaudeUpstreamHandlers>[0]> = {}) {
    return makeClaudeUpstreamHandlers({
      resolveUsageTeam: async () => ({ ok: true, teamId: "team_1", stackUserId: "user_1" }),
      resolveContext: mock(async () => context) as never,
      describe: service.describe,
      put: service.put,
      remove: service.remove,
      ...overrides,
    });
  }

  function putRequest(body: unknown): Request {
    return new Request("https://coderouter.dev/api/coderouter/claude-upstream?teamId=team_1", {
      method: "PUT",
      headers: { "content-type": "application/json" },
      body: typeof body === "string" ? body : JSON.stringify(body),
    });
  }

  test("requires manage permission for PUT and DELETE", async () => {
    const { PUT, DELETE } = handlers({ resolveContext: mock(async () => forbidden) as never });
    expect((await PUT(putRequest({ kind: "anthropic_api_key", apiKey: API_KEY }))).status).toBe(403);
    expect((await DELETE(putRequest(""))).status).toBe(403);
    expect(store.rows.size).toBe(0);
  });

  test("rejects malformed and invalid bodies", async () => {
    const { PUT } = handlers();
    expect((await PUT(putRequest("{not json"))).status).toBe(400);
    expect((await PUT(putRequest({ kind: "anthropic_api_key", apiKey: "nope" }))).status).toBe(400);
    expect((await PUT(putRequest({ kind: "bedrock", region: "us-east-1" }))).status).toBe(400);
    expect(store.rows.size).toBe(0);
  });

  test("rejects oversized bodies", async () => {
    const { PUT } = handlers();
    const response = await PUT(
      putRequest({ kind: "anthropic_api_key", apiKey: API_KEY, padding: "x".repeat(70 * 1024) }),
    );
    expect(response.status).toBe(413);
  });

  test("sets, describes, replaces and removes the upstream", async () => {
    const { GET, PUT, DELETE } = handlers();
    const empty = await GET(new Request("https://coderouter.dev/api/coderouter/claude-upstream"));
    expect(await empty.json()).toEqual({ teamId: "team_1", upstream: null });

    const created = await PUT(putRequest({ kind: "anthropic_api_key", apiKey: API_KEY }));
    expect(created.status).toBe(201);
    const createdBody = await created.json();
    expect(createdBody.upstream).toMatchObject({ kind: "anthropic_api_key", identifier: "sk-ant-...6789" });
    expect(JSON.stringify(createdBody)).not.toContain(API_KEY);

    const replaced = await PUT(putRequest({ kind: "anthropic_oauth", token: OAUTH_TOKEN }));
    expect(replaced.status).toBe(200);

    const described = await GET(new Request("https://coderouter.dev/api/coderouter/claude-upstream"));
    const describedBody = await described.json();
    expect(describedBody.upstream.kind).toBe("anthropic_oauth");
    expect(JSON.stringify(describedBody)).not.toContain(OAUTH_TOKEN);
    expect(described.headers.get("cache-control")).toBe("no-store");

    const removed = await DELETE(new Request("https://coderouter.dev/api/coderouter/claude-upstream", { method: "DELETE" }));
    expect(await removed.json()).toEqual({ removed: true });
    const missing = await DELETE(new Request("https://coderouter.dev/api/coderouter/claude-upstream", { method: "DELETE" }));
    expect(missing.status).toBe(404);
  });

  test("fails closed when storage is unavailable", async () => {
    const { PUT } = handlers({
      put: async () => {
        throw new Error("database unavailable");
      },
    });
    const response = await PUT(putRequest({ kind: "anthropic_api_key", apiKey: API_KEY }));
    expect(response.status).toBe(503);
    await expect(response.json()).resolves.toMatchObject({ error: "claude_upstream_unavailable", retryable: true });
  });
});
