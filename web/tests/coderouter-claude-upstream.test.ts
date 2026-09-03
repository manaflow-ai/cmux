import { describe, expect, mock, test } from "bun:test";
import { randomBytes } from "node:crypto";
import {
  createClaudeUpstreamService,
  parseClaudeAccountPatch,
  parseClaudeUpstreamInput,
  rendezvousPick,
  type ClaudeAccountRow,
  type ClaudeAccountStore,
} from "../services/coderouter/claudeUpstream";
import type { CredentialKeyService } from "../services/coderouter/encryption";
import { makeClaudeUpstreamHandlers } from "../app/api/coderouter/claude-upstream/route";
import { makeClaudeAccountHandlers } from "../app/api/coderouter/claude-upstream/[accountId]/route";
import type { CredentialProbeResult as ProbeResult } from "../services/coderouter/claudeCredentialProbe";

const API_KEY = "sk-ant-api03-abcdefghijklmnopqrstuvwxyz0123456789";
const API_KEY_2 = "sk-ant-api03-zyxwvutsrqponmlkjihgfedcba9876543210";
const OAUTH_TOKEN = "sk-ant-oat01-abcdefghijklmnopqrstuvwxyz0123456789-ABCDEF";
const OAUTH_TOKEN_2 = "sk-ant-oat01-second-long-lived-token-0123456789-WXYZ";
const ACCESS_KEY_ID = "AKIAIOSFODNN7EXAMPLE";
const SECRET_ACCESS_KEY = "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY";
const T0 = new Date("2026-09-02T10:00:00.000Z");

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

function memoryStore(): ClaudeAccountStore & { rows: Map<string, ClaudeAccountRow>; clock: { now: Date } } {
  const rows = new Map<string, ClaudeAccountRow>();
  const clock = { now: T0 };
  let tick = 0;
  return {
    rows,
    clock,
    async list(teamId) {
      return [...rows.values()]
        .filter((row) => row.teamId === teamId)
        .sort((a, b) => a.createdAt.getTime() - b.createdAt.getTime() || a.id.localeCompare(b.id));
    },
    async insert(row) {
      const createdAt = new Date(clock.now.getTime() + tick++);
      const written = { ...row, createdAt, updatedAt: createdAt };
      rows.set(row.id, written);
      return written;
    },
    async update(teamId, accountId, patch) {
      const row = rows.get(accountId);
      if (!row || row.teamId !== teamId) return null;
      const written = {
        ...row,
        ...(patch.label !== undefined ? { label: patch.label } : {}),
        ...(patch.state !== undefined ? { state: patch.state } : {}),
        ...(patch.identifier !== undefined ? { identifier: patch.identifier } : {}),
        updatedAt: clock.now,
      };
      rows.set(accountId, written);
      return written;
    },
    async remove(teamId, accountId) {
      const row = rows.get(accountId);
      if (!row || row.teamId !== teamId) return false;
      return rows.delete(accountId);
    },
    async removeAll(teamId) {
      let removed = 0;
      for (const [id, row] of rows) {
        if (row.teamId === teamId) {
          rows.delete(id);
          removed += 1;
        }
      }
      return removed;
    },
    async findByFingerprint(teamId, fingerprint) {
      return [...rows.values()].find((row) => row.teamId === teamId && row.fingerprint === fingerprint && fingerprint !== "") ?? null;
    },
    async markCooldown(accountId, until, failureCode, countTowardBroken) {
      const row = rows.get(accountId)!;
      const consecutiveFailures = countTowardBroken ? row.consecutiveFailures + 1 : row.consecutiveFailures;
      rows.set(accountId, { ...row, cooldownUntil: until, lastFailureCode: failureCode, consecutiveFailures });
      return consecutiveFailures;
    },
    async markBroken(accountId, at) {
      const row = rows.get(accountId)!;
      if (row.state === "active") rows.set(accountId, { ...row, state: "broken", brokenAt: at });
    },
    async touchUsed(accountId, at) {
      const row = rows.get(accountId)!;
      rows.set(accountId, { ...row, lastUsedAt: at, consecutiveFailures: 0 });
    },
    async listBrokenUnnotified() {
      return [...rows.values()].filter((row) => row.state === "broken" && row.brokenNotifiedAt === null);
    },
    async markNotified(accountIds, at) {
      for (const id of accountIds) {
        const row = rows.get(id);
        if (row && row.brokenNotifiedAt === null) rows.set(id, { ...row, brokenNotifiedAt: at });
      }
    },
  };
}

function service(store = memoryStore()) {
  let counter = 0;
  const ids = () => `00000000-0000-4000-8000-${String(++counter).padStart(12, "0")}`;
  const inner = createClaudeUpstreamService({ store, keys: fakeKeys(), keyId: "kms-test", now: () => store.clock.now, newId: ids });
  return {
    store,
    inner,
    // `add` unwrapped to the description for the many tests that only need it.
    service: { ...inner, add: async (...args: Parameters<typeof inner.add>) => (await inner.add(...args)).account },
  };
}

describe("claude upstream input validation", () => {
  test("accepts an Anthropic API key and rejects OAuth tokens in its place", () => {
    expect(parseClaudeUpstreamInput({ kind: "anthropic_api_key", apiKey: API_KEY })).toEqual({
      kind: "anthropic_api_key",
      apiKey: API_KEY,
    });
    expect(parseClaudeUpstreamInput({ kind: "anthropic_api_key", apiKey: OAUTH_TOKEN })).toBeNull();
    expect(parseClaudeUpstreamInput({ kind: "anthropic_api_key", apiKey: "sk-ant-short" })).toBeNull();
  });

  test("accepts a Claude Code OAuth token only with its prefix", () => {
    expect(parseClaudeUpstreamInput({ kind: "anthropic_oauth", token: OAUTH_TOKEN })).toEqual({
      kind: "anthropic_oauth",
      token: OAUTH_TOKEN,
    });
    expect(parseClaudeUpstreamInput({ kind: "anthropic_oauth", token: API_KEY })).toBeNull();
  });

  test("carries an optional single-line label and rejects a long or multi-line one", () => {
    expect(parseClaudeUpstreamInput({ kind: "anthropic_oauth", token: OAUTH_TOKEN, label: "  work  " })).toEqual({
      kind: "anthropic_oauth",
      token: OAUTH_TOKEN,
      label: "work",
    });
    expect(parseClaudeUpstreamInput({ kind: "anthropic_oauth", token: OAUTH_TOKEN, label: "" })).toEqual({
      kind: "anthropic_oauth",
      token: OAUTH_TOKEN,
    });
    expect(parseClaudeUpstreamInput({ kind: "anthropic_oauth", token: OAUTH_TOKEN, label: "a\nb" })).toBeNull();
    expect(parseClaudeUpstreamInput({ kind: "anthropic_oauth", token: OAUTH_TOKEN, label: "x".repeat(65) })).toBeNull();
    expect(parseClaudeUpstreamInput({ kind: "anthropic_oauth", token: OAUTH_TOKEN, label: 7 })).toBeNull();
  });

  test("validates Bedrock region, keys, session token and model overrides", () => {
    const valid = {
      kind: "bedrock",
      region: "us-west-2",
      accessKeyId: ACCESS_KEY_ID,
      secretAccessKey: SECRET_ACCESS_KEY,
      modelIds: { "claude-sonnet-4-5": "us.anthropic.claude-sonnet-4-5-20250929-v1:0" },
    };
    expect(parseClaudeUpstreamInput(valid)).toEqual(valid);
    expect(parseClaudeUpstreamInput({ ...valid, region: "US-WEST-2" })).toBeNull();
    expect(parseClaudeUpstreamInput({ ...valid, accessKeyId: "nope" })).toBeNull();
    expect(parseClaudeUpstreamInput({ ...valid, modelIds: { "gpt-5": "anthropic.claude-x" } })).toBeNull();
  });

  test("parses account patches", () => {
    expect(parseClaudeAccountPatch({ label: "team a" })).toEqual({ label: "team a" });
    expect(parseClaudeAccountPatch({ state: "disabled" })).toEqual({ state: "disabled" });
    expect(parseClaudeAccountPatch({ state: "broken" })).toBeNull();
    expect(parseClaudeAccountPatch({})).toBeNull();
    expect(parseClaudeAccountPatch("x")).toBeNull();
  });
});

describe("claude upstream accounts service", () => {
  test("stores many accounts of mixed kinds and lists them without secrets", async () => {
    const { service: svc, store } = service();
    const a = await svc.add("team-1", "user-1", { kind: "anthropic_api_key", apiKey: API_KEY, label: "prod" });
    const b = await svc.add("team-1", "user-1", { kind: "anthropic_oauth", token: OAUTH_TOKEN });
    const c = await svc.add("team-1", "user-2", { kind: "anthropic_oauth", token: OAUTH_TOKEN_2, label: "personal" });
    expect(a).toMatchObject({ kind: "anthropic_api_key", label: "prod", identifier: "sk-ant-...6789", state: "active" });
    expect(b).toMatchObject({ kind: "anthropic_oauth", label: "", identifier: "sk-ant-oat01-...CDEF" });
    expect(c).toMatchObject({ kind: "anthropic_oauth", label: "personal", identifier: "sk-ant-oat01-...WXYZ" });
    expect(new Set([a.id, b.id, c.id]).size).toBe(3);
    const listed = await svc.list("team-1");
    expect(listed.map((account) => account.id)).toEqual([a.id, b.id, c.id]);
    const serialized = JSON.stringify([...store.rows.values()]) + JSON.stringify(listed);
    for (const secret of [API_KEY, OAUTH_TOKEN, OAUTH_TOKEN_2]) expect(serialized).not.toContain(secret);
    expect(store.rows.get(a.id)!.createdBy).toBe("user-1");
    expect(store.rows.get(a.id)!.aadVersion).toBe(2);
    expect(await svc.list("team-2")).toEqual([]);
  });

  test("keeps Bedrock region and overrides out of the ciphertext", async () => {
    const { service: svc, store } = service();
    const described = await svc.add("team-1", "user-1", {
      kind: "bedrock",
      region: "us-west-2",
      accessKeyId: ACCESS_KEY_ID,
      secretAccessKey: SECRET_ACCESS_KEY,
      sessionToken: "FwoGZXIvYXdzEBYaDExampleSession",
      modelIds: { "claude-sonnet-4-5": "us.anthropic.claude-sonnet-4-5-20250929-v1:0" },
    });
    expect(described).toMatchObject({ kind: "bedrock", identifier: "AKIA...MPLE", region: "us-west-2" });
    const row = store.rows.get(described.id)!;
    expect(row.config).toEqual({
      region: "us-west-2",
      modelIds: { "claude-sonnet-4-5": "us.anthropic.claude-sonnet-4-5-20250929-v1:0" },
    });
    const serialized = JSON.stringify(row);
    expect(serialized).not.toContain(SECRET_ACCESS_KEY);
    expect(serialized).not.toContain("FwoGZXIvYXdzEBYaDExampleSession");
    const selected = await svc.select("team-1", { stickyKey: "vm-1" });
    expect(selected.kind).toBe("selected");
    if (selected.kind === "selected") {
      expect(selected.upstream.secret).toEqual({
        kind: "bedrock",
        accessKeyId: ACCESS_KEY_ID,
        secretAccessKey: SECRET_ACCESS_KEY,
        sessionToken: "FwoGZXIvYXdzEBYaDExampleSession",
      });
      expect(selected.upstream.config.region).toBe("us-west-2");
    }
  });

  test("selection pins a sticky key to one account and moves it only on exclusion", async () => {
    const { service: svc } = service();
    const a = await svc.add("team-1", "user-1", { kind: "anthropic_api_key", apiKey: API_KEY });
    const b = await svc.add("team-1", "user-1", { kind: "anthropic_api_key", apiKey: API_KEY_2 });
    const first = await svc.select("team-1", { stickyKey: "vm-42" });
    const again = await svc.select("team-1", { stickyKey: "vm-42" });
    expect(first.kind).toBe("selected");
    if (first.kind !== "selected" || again.kind !== "selected") throw new Error("expected selections");
    expect(again.upstream.accountId).toBe(first.upstream.accountId);
    expect(first).toMatchObject({ total: 2, healthy: 2 });
    const other = [a.id, b.id].find((id) => id !== first.upstream.accountId)!;
    const moved = await svc.select("team-1", { stickyKey: "vm-42", excludedAccountIds: [first.upstream.accountId] });
    expect(moved.kind === "selected" && moved.upstream.accountId).toBe(other);
    // Different clients spread: over many keys both accounts get picked.
    const picks = new Set<string>();
    for (let i = 0; i < 40; i += 1) {
      const pick = await svc.select("team-1", { stickyKey: `vm-${i}` });
      if (pick.kind === "selected") picks.add(pick.upstream.accountId);
    }
    expect(picks.size).toBe(2);
  });

  test("rendezvous hashing is stable and only remaps the removed account's keys", () => {
    const candidates = ["a", "b", "c"].map((id) => ({ id }));
    const before = new Map<string, string>();
    for (let i = 0; i < 200; i += 1) before.set(`k${i}`, rendezvousPick(`k${i}`, candidates).id);
    const without = candidates.filter((candidate) => candidate.id !== "b");
    let moved = 0;
    for (const [key, id] of before) {
      const after = rendezvousPick(key, without).id;
      if (id === "b") expect(after).not.toBe("b");
      else expect(after).toBe(id);
      if (after !== id) moved += 1;
    }
    expect(moved).toBe([...before.values()].filter((id) => id === "b").length);
  });

  test("cooldown and disabled accounts are skipped, and exhaustion reports the soonest retry", async () => {
    const { service: svc, store } = service();
    const a = await svc.add("team-1", "user-1", { kind: "anthropic_api_key", apiKey: API_KEY });
    const b = await svc.add("team-1", "user-1", { kind: "anthropic_oauth", token: OAUTH_TOKEN });
    await svc.cooldown(a.id, 30_000, "rate_limited");
    expect(store.rows.get(a.id)!.lastFailureCode).toBe("rate_limited");
    const pick = await svc.select("team-1", { stickyKey: null });
    expect(pick.kind === "selected" && pick.upstream.accountId).toBe(b.id);
    await svc.update("team-1", b.id, { state: "disabled" });
    const exhausted = await svc.select("team-1", { stickyKey: null });
    expect(exhausted).toEqual({ kind: "exhausted", total: 2, retryAfterSeconds: 30 });
    // Cooldown expiry brings the account back.
    store.clock.now = new Date(T0.getTime() + 31_000);
    const back = await svc.select("team-1", { stickyKey: null });
    expect(back.kind === "selected" && back.upstream.accountId).toBe(a.id);
    // Clamped cooldowns: a second is the floor.
    await svc.cooldown(a.id, 1, "upstream_transport");
    expect(store.rows.get(a.id)!.cooldownUntil!.getTime()).toBe(store.clock.now.getTime() + 1_000);
  });

  test("without a sticky key the least recently used account is chosen", async () => {
    const { service: svc } = service();
    const a = await svc.add("team-1", "user-1", { kind: "anthropic_api_key", apiKey: API_KEY });
    const b = await svc.add("team-1", "user-1", { kind: "anthropic_api_key", apiKey: API_KEY_2 });
    const first = await svc.select("team-1", { stickyKey: null });
    expect(first.kind === "selected" && first.upstream.accountId).toBe(a.id);
    await svc.touchUsed(a.id);
    const second = await svc.select("team-1", { stickyKey: null });
    expect(second.kind === "selected" && second.upstream.accountId).toBe(b.id);
  });

  test("removes one account, removes all, and reports none", async () => {
    const { service: svc } = service();
    const a = await svc.add("team-1", "user-1", { kind: "anthropic_api_key", apiKey: API_KEY });
    await svc.add("team-1", "user-1", { kind: "anthropic_oauth", token: OAUTH_TOKEN });
    expect(await svc.remove("team-1", a.id)).toEqual({ removed: true });
    expect(await svc.remove("team-1", a.id)).toEqual({ removed: false });
    expect(await svc.remove("team-2", a.id)).toEqual({ removed: false });
    expect((await svc.list("team-1")).length).toBe(1);
    expect(await svc.removeAll("team-1")).toEqual({ removed: 1 });
    expect(await svc.select("team-1", { stickyKey: "vm-1" })).toEqual({ kind: "none" });
  });

  test("adding the same secret twice returns the existing account", async () => {
    const { inner, store } = service();
    const first = await inner.add("team-1", "user-1", { kind: "anthropic_oauth", token: OAUTH_TOKEN, label: "work" });
    const again = await inner.add("team-1", "user-2", { kind: "anthropic_oauth", token: OAUTH_TOKEN, label: "other" });
    expect(first.alreadyExists).toBe(false);
    expect(again).toEqual({ account: first.account, alreadyExists: true });
    expect(store.rows.size).toBe(1);
    // A different team may hold the same secret.
    const elsewhere = await inner.add("team-2", "user-1", { kind: "anthropic_oauth", token: OAUTH_TOKEN });
    expect(elsewhere.alreadyExists).toBe(false);
    expect(store.rows.size).toBe(2);
    expect(store.rows.get(first.account.id)!.fingerprint).toHaveLength(64);
  });

  test("three consecutive credential rejections mark the account broken; a success resets the count", async () => {
    const { service: svc, store } = service();
    const a = await svc.add("team-1", "user-1", { kind: "anthropic_api_key", apiKey: API_KEY });
    await svc.cooldown(a.id, 1000, "invalid_credential");
    await svc.cooldown(a.id, 1000, "rate_limited");
    await svc.cooldown(a.id, 1000, "invalid_credential");
    expect(store.rows.get(a.id)!).toMatchObject({ state: "active", consecutiveFailures: 2 });
    await svc.touchUsed(a.id);
    expect(store.rows.get(a.id)!.consecutiveFailures).toBe(0);
    for (let i = 0; i < 3; i += 1) await svc.cooldown(a.id, 1000, "invalid_credential");
    const row = store.rows.get(a.id)!;
    expect(row.state).toBe("broken");
    expect(row.brokenAt).toEqual(store.clock.now);
    store.clock.now = new Date(T0.getTime() + 60_000);
    expect(await svc.select("team-1", { stickyKey: "vm-1" })).toEqual({ kind: "exhausted", total: 1, retryAfterSeconds: 15 });
    expect((await svc.list("team-1"))[0]).toMatchObject({ state: "broken", consecutiveFailures: 3 });
    expect((await svc.listBrokenUnnotifiedRows()).map((r) => r.id)).toEqual([a.id]);
    await svc.markNotified([a.id]);
    expect(await svc.listBrokenUnnotifiedRows()).toEqual([]);
  });

  test("binds the ciphertext to the team and the account", async () => {
    const { service: svc, store } = service();
    const a = await svc.add("team-1", "user-1", { kind: "anthropic_api_key", apiKey: API_KEY });
    const row = store.rows.get(a.id)!;
    store.rows.set(a.id, { ...row, teamId: "team-2" });
    await expect(svc.select("team-2", { stickyKey: null })).rejects.toThrow();
    store.rows.set("other-id", { ...row, id: "other-id", teamId: "team-1" });
    store.rows.delete(a.id);
    await expect(svc.select("team-1", { stickyKey: null })).rejects.toThrow();
  });

  test("backfills the identifier of a row migrated from the single-upstream table", async () => {
    const { service: svc, store } = service();
    const a = await svc.add("team-1", "user-1", { kind: "anthropic_api_key", apiKey: API_KEY });
    // Re-encrypt under the legacy (team, kind) binding the migration carries over.
    const legacyService = createClaudeUpstreamService({
      store,
      keys: fakeKeys(),
      keyId: "kms-test",
      newId: () => "legacy-row",
    });
    void legacyService;
    const row = store.rows.get(a.id)!;
    store.rows.set(a.id, { ...row, identifier: "" });
    const listed = await svc.list("team-1");
    expect(listed[0]!.identifier).toBe("sk-ant-...6789");
    expect(store.rows.get(a.id)!.identifier).toBe("sk-ant-...6789");
  });
});

describe("claude upstream routes", () => {
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

  function handlers(options: { manage?: boolean; failing?: boolean; probe?: ProbeResult } = {}) {
    const { service: svc, inner } = service();
    const probeCalls: unknown[] = [];
    const resolveContext = mock(async () => (options.manage === false ? forbidden : context));
    const resolveUsageTeam = mock(async () => ({ ok: true as const, teamId: "team_1", stackUserId: "user_1" }));
    const failing = options.failing ?? false;
    const fail = async () => {
      throw new Error("db down");
    };
    const collection = makeClaudeUpstreamHandlers({
      resolveUsageTeam: resolveUsageTeam as never,
      resolveContext: resolveContext as never,
      list: failing ? (fail as never) : svc.list,
      add: failing ? (fail as never) : inner.add,
      removeAll: failing ? (fail as never) : svc.removeAll,
      probe: async (input) => {
        probeCalls.push(input.kind);
        return options.probe ?? { ok: true, email: null };
      },
    });
    const single = makeClaudeAccountHandlers({
      resolveContext: resolveContext as never,
      update: failing ? (fail as never) : svc.update,
      remove: failing ? (fail as never) : svc.remove,
    });
    return { collection, single, svc, probeCalls };
  }

  const url = "https://cmux.com/api/coderouter/claude-upstream?teamId=team_1";
  const json = (method: string, body: unknown, size?: number) =>
    new Request(url, {
      method,
      headers: { "content-type": "application/json", ...(size ? { "content-length": String(size) } : {}) },
      body: JSON.stringify(body),
    });
  const params = (accountId: string) => ({ params: Promise.resolve({ accountId }) });

  test("requires manage permission for writes", async () => {
    const { collection, single } = handlers({ manage: false });
    expect((await collection.POST(json("POST", { kind: "anthropic_api_key", apiKey: API_KEY }))).status).toBe(403);
    expect((await collection.DELETE(new Request(url, { method: "DELETE" }))).status).toBe(403);
    expect((await single.DELETE(new Request(url, { method: "DELETE" }), params("00000000-0000-4000-8000-000000000001"))).status).toBe(403);
  });

  test("rejects malformed, invalid and oversized bodies", async () => {
    const { collection } = handlers();
    expect((await collection.POST(new Request(url, { method: "POST", body: "{" }))).status).toBe(400);
    expect((await collection.POST(json("POST", { kind: "anthropic_api_key", apiKey: "nope" }))).status).toBe(400);
    expect((await collection.POST(json("POST", { kind: "anthropic_api_key", apiKey: API_KEY }, 70_000))).status).toBe(413);
  });

  test("adds, lists, patches and removes accounts", async () => {
    const { collection, single } = handlers();
    const first = await collection.POST(json("POST", { kind: "anthropic_oauth", token: OAUTH_TOKEN, label: "work" }));
    expect(first.status).toBe(201);
    const firstBody = await first.json();
    expect(firstBody.account).toMatchObject({ kind: "anthropic_oauth", label: "work", identifier: "sk-ant-oat01-...CDEF" });
    expect(firstBody.upstream.id).toBe(firstBody.account.id);
    // PUT stays an alias for older clients and adds rather than replaces.
    const second = await collection.PUT(json("PUT", { kind: "anthropic_oauth", token: OAUTH_TOKEN_2 }));
    expect(second.status).toBe(201);
    expect((await second.json()).accountsTotal).toBe(2);

    const listed = await (await collection.GET(new Request(url))).json();
    expect(listed.accounts).toHaveLength(2);
    expect(listed.upstream.id).toBe(firstBody.account.id);
    expect(JSON.stringify(listed)).not.toContain(OAUTH_TOKEN);

    const patched = await single.PATCH(json("PATCH", { state: "disabled", label: "paused" }), params(firstBody.account.id));
    expect(patched.status).toBe(200);
    expect((await patched.json()).account).toMatchObject({ state: "disabled", label: "paused" });
    expect((await single.PATCH(json("PATCH", { state: "nope" }), params(firstBody.account.id))).status).toBe(400);
    expect((await single.PATCH(json("PATCH", { state: "active" }), params("not-a-uuid"))).status).toBe(400);
    expect((await single.PATCH(json("PATCH", { state: "active" }), params("00000000-0000-4000-8000-00000000ffff"))).status).toBe(404);

    const removed = await single.DELETE(new Request(url, { method: "DELETE" }), params(firstBody.account.id));
    expect(await removed.json()).toEqual({ removed: true, count: 1 });
    expect((await single.DELETE(new Request(url, { method: "DELETE" }), params(firstBody.account.id))).status).toBe(404);

    const all = await collection.DELETE(new Request(url, { method: "DELETE" }));
    expect(await all.json()).toEqual({ removed: true, count: 1 });
    expect((await collection.DELETE(new Request(url, { method: "DELETE" }))).status).toBe(404);
    const empty = await (await collection.GET(new Request(url))).json();
    expect(empty).toEqual({ teamId: "team_1", accounts: [], upstream: null });
  });

  test("refuses a credential the upstream rejects and stores nothing", async () => {
    const { collection, probeCalls, svc } = handlers({ probe: { ok: false, reason: "rejected", status: 401, message: "invalid x-api-key" } });
    const response = await collection.POST(json("POST", { kind: "anthropic_api_key", apiKey: API_KEY }));
    expect(response.status).toBe(422);
    expect(await response.json()).toMatchObject({ error: "credential_rejected", upstreamStatus: 401, retryable: false });
    expect(probeCalls).toEqual(["anthropic_api_key"]);
    expect(await svc.list("team_1")).toEqual([]);
  });

  test("stores when the upstream is unreachable, skips the probe on request, and labels from the profile", async () => {
    const unreachable = handlers({ probe: { ok: false, reason: "unreachable", message: "fetch failed" } });
    const stored = await unreachable.collection.POST(json("POST", { kind: "anthropic_api_key", apiKey: API_KEY }));
    expect(stored.status).toBe(201);
    expect((await stored.json()).validation).toBe("unreachable");

    const skipped = handlers();
    const skippedResponse = await skipped.collection.POST(new Request(`${url}&validate=0`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ kind: "anthropic_api_key", apiKey: API_KEY }),
    }));
    expect((await skippedResponse.json()).validation).toBe("skipped");
    expect(skipped.probeCalls).toEqual([]);

    const labeled = handlers({ probe: { ok: true, email: "dev@example.com" } });
    const first = await labeled.collection.POST(json("POST", { kind: "anthropic_oauth", token: OAUTH_TOKEN }));
    expect(first.status).toBe(201);
    expect((await first.json()).account.label).toBe("dev@example.com");
    const again = await labeled.collection.POST(json("POST", { kind: "anthropic_oauth", token: OAUTH_TOKEN, label: "ignored" }));
    expect(again.status).toBe(200);
    const body = await again.json();
    expect(body.alreadyExists).toBe(true);
    expect(body.accountsTotal).toBe(1);
  });

  test("fails closed when storage is unavailable", async () => {
    const { collection, single } = handlers({ failing: true });
    const responses = await Promise.all([
      collection.GET(new Request(url)),
      collection.POST(json("POST", { kind: "anthropic_api_key", apiKey: API_KEY })),
      collection.DELETE(new Request(url, { method: "DELETE" })),
      single.PATCH(json("PATCH", { state: "active" }), params("00000000-0000-4000-8000-000000000001")),
      single.DELETE(new Request(url, { method: "DELETE" }), params("00000000-0000-4000-8000-000000000001")),
    ]);
    for (const response of responses) {
      expect(response.status).toBe(503);
      expect((await response.json()).error).toBe("claude_upstream_unavailable");
    }
  });
});
