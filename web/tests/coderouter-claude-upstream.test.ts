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

type TestAccess = { readonly kind: string; readonly userId?: string };

// Mirrors accountAccessPredicate: a reader sees shared rows and its own private
// ones; an "own-private" writer reaches only its own private rows.
function visibleTo(row: ClaudeAccountRow, access?: TestAccess): boolean {
  if (!access) return true;
  const visibility = row.visibility ?? "team";
  if (access.kind === "own-private") return visibility === "private" && row.createdBy === access.userId;
  if (access.kind === "user") return visibility === "team" || row.createdBy === access.userId;
  return visibility === "team";
}

function memoryStore(): ClaudeAccountStore & { rows: Map<string, ClaudeAccountRow>; clock: { now: Date } } {
  const rows = new Map<string, ClaudeAccountRow>();
  const clock = { now: T0 };
  let tick = 0;
  const reachable = (teamId: string, accountId: string, access?: TestAccess) => {
    const row = rows.get(accountId);
    return row && row.teamId === teamId && visibleTo(row, access) ? row : null;
  };
  return {
    rows,
    clock,
    async list(teamId, _signal, access?: TestAccess) {
      return [...rows.values()]
        .filter((row) => row.teamId === teamId && visibleTo(row, access))
        .sort((a, b) => a.createdAt.getTime() - b.createdAt.getTime() || a.id.localeCompare(b.id));
    },
    async insert(row) {
      const createdAt = new Date(clock.now.getTime() + tick++);
      const written = { ...row, createdAt, updatedAt: createdAt };
      rows.set(row.id, written);
      return written;
    },
    async update(teamId, accountId, patch, access?: TestAccess) {
      const row = reachable(teamId, accountId, access);
      if (!row) return null;
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
    async remove(teamId, accountId, access?: TestAccess) {
      return reachable(teamId, accountId, access) ? rows.delete(accountId) : false;
    },
    async removeAll(teamId, access?: TestAccess) {
      let removed = 0;
      for (const [id, row] of rows) {
        if (row.teamId === teamId && visibleTo(row, access)) {
          rows.delete(id);
          removed += 1;
        }
      }
      return removed;
    },
    async markCooldown(accountId, until, failureCode) {
      const row = rows.get(accountId)!;
      rows.set(accountId, { ...row, cooldownUntil: until, lastFailureCode: failureCode });
    },
    async touchUsed(accountId, at) {
      const row = rows.get(accountId)!;
      rows.set(accountId, { ...row, lastUsedAt: at });
    },
  };
}

function service(store = memoryStore()) {
  let counter = 0;
  const ids = () => `00000000-0000-4000-8000-${String(++counter).padStart(12, "0")}`;
  return {
    store,
    service: createClaudeUpstreamService({ store, keys: fakeKeys(), keyId: "kms-test", now: () => store.clock.now, newId: ids }),
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
  const TEAM = { teamId: "team_1", teamName: "Benjamin Swerdlow's Team", use: true };
  const signedIn = (userId: string, manageAccounts: boolean) => ({
    ok: true as const,
    value: {
      user: { id: userId },
      access: { kind: "user" as const, userId },
      team: { ...TEAM, manageAccounts },
    },
  });
  const context = signedIn("user_1", true);
  // A team member without the Stack `$manage_api_keys` team permission.
  const member = signedIn("user_2", false);
  const vm = {
    ok: true as const,
    value: {
      user: { id: "user_1" },
      access: { kind: "vm" as const, vmId: "vm_1", poolId: "pool_1" },
      team: { ...TEAM, manageAccounts: true },
    },
  };
  const forbidden = {
    ok: false as const,
    response: Response.json({ error: "forbidden" }, { status: 403 }),
  };
  type Resolved = typeof context | typeof vm | typeof forbidden;

  function handlers(options: { manage?: boolean; failing?: boolean } = {}) {
    const { service: svc, store } = service();
    let current: Resolved = options.manage === false ? forbidden : context;
    const resolveContext = mock(async () => current);
    const resolveUsageTeam = mock(async () => ({ ok: true as const, teamId: "team_1", stackUserId: "user_1" }));
    const failing = options.failing ?? false;
    const fail = async () => {
      throw new Error("db down");
    };
    const collection = makeClaudeUpstreamHandlers({
      resolveUsageTeam: resolveUsageTeam as never,
      resolveContext: resolveContext as never,
      list: failing ? (fail as never) : svc.list,
      add: failing ? (fail as never) : svc.add,
      removeAll: failing ? (fail as never) : svc.removeAll,
    });
    const single = makeClaudeAccountHandlers({
      resolveContext: resolveContext as never,
      list: failing ? (fail as never) : svc.list,
      update: failing ? (fail as never) : svc.update,
      remove: failing ? (fail as never) : svc.remove,
    } as Parameters<typeof makeClaudeAccountHandlers>[0]);
    const actAs = (next: Resolved) => {
      current = next;
    };
    return { collection, single, svc, store, actAs };
  }

  const url = "https://cmux.com/api/coderouter/claude-upstream?teamId=team_1";
  const json = (method: string, body: unknown, size?: number) =>
    new Request(url, {
      method,
      headers: { "content-type": "application/json", ...(size ? { "content-length": String(size) } : {}) },
      body: JSON.stringify(body),
    });
  const params = (accountId: string) => ({ params: Promise.resolve({ accountId }) });
  const del = () => new Request(url, { method: "DELETE" });

  async function expectPermissionRequired(response: Response, action: string, optionKinds: readonly string[]) {
    expect(response.status).toBe(403);
    expect(response.headers.get("cache-control")).toBe("no-store");
    const body = await response.json();
    expect(body).toMatchObject({
      error: "forbidden",
      code: "team_permission_required",
      teamId: "team_1",
      teamName: "Benjamin Swerdlow's Team",
      permission: "$manage_api_keys",
      action,
      retryable: false,
    });
    expect(body.message).toContain("Benjamin Swerdlow's Team");
    expect(body.message).toContain("$manage_api_keys");
    expect(body.options.map((option: { kind: string }) => option.kind)).toEqual(optionKinds);
    return body;
  }

  test("a caller the team context refuses cannot write", async () => {
    const { collection, single } = handlers({ manage: false });
    expect((await collection.POST(json("POST", { kind: "anthropic_api_key", apiKey: API_KEY }))).status).toBe(403);
    expect((await collection.DELETE(del())).status).toBe(403);
    expect((await single.DELETE(del(), params("00000000-0000-4000-8000-000000000001"))).status).toBe(403);
  });

  test("a member without account administration adds a private account", async () => {
    const { collection, store, actAs } = handlers();
    actAs(member);
    const response = await collection.POST(json("POST", { kind: "anthropic_oauth", token: OAUTH_TOKEN, label: "hq" }));
    expect(response.status).toBe(201);
    const body = await response.json();
    expect(body.account).toMatchObject({ kind: "anthropic_oauth", label: "hq", createdBy: "user_2", visibility: "private" });
    expect(body.upstream.id).toBe(body.account.id);
    expect(store.rows.get(body.account.id)).toMatchObject({ createdBy: "user_2", visibility: "private" });
    // An explicit private request is the same write.
    const explicit = await collection.POST(json("POST", { kind: "anthropic_oauth", token: OAUTH_TOKEN_2, visibility: "private" }));
    expect(explicit.status).toBe(201);
    expect(store.rows.size).toBe(2);
  });

  test("a member's malformed token is a validation error, not a permission error", async () => {
    const { collection, store, actAs } = handlers();
    actAs(member);
    const response = await collection.POST(json("POST", { kind: "anthropic_oauth", token: "sk-ant-not-a-real-token", label: "hq-repro" }));
    expect(response.status).toBe(400);
    expect(await response.json()).toEqual({ error: "invalid_request" });
    expect(store.rows.size).toBe(0);
  });

  test("sharing a new account with the team needs account administration", async () => {
    const { collection, store, actAs } = handlers();
    actAs(member);
    const response = await collection.POST(json("POST", { kind: "anthropic_oauth", token: OAUTH_TOKEN, visibility: "team" }));
    const body = await expectPermissionRequired(response, "share_account", ["private", "switch_team", "ask_admin"]);
    expect(body.options[0].command).toBe("cr add claude --private");
    expect(body.options[1].command).toBe("cr org switch <team>");
    expect(JSON.stringify(body)).not.toContain(OAUTH_TOKEN);
    expect(store.rows.size).toBe(0);

    actAs(context);
    const shared = await collection.POST(json("POST", { kind: "anthropic_oauth", token: OAUTH_TOKEN, visibility: "team" }));
    expect(shared.status).toBe(201);
    expect((await shared.json()).account.visibility).toBe("team");
  });

  test("a member changes and removes only their own private accounts", async () => {
    const { collection, single, store, actAs } = handlers();
    const shared = await (await collection.POST(json("POST", { kind: "anthropic_api_key", apiKey: API_KEY, visibility: "team" }))).json();
    const adminPrivate = await (await collection.POST(json("POST", { kind: "anthropic_api_key", apiKey: API_KEY_2 }))).json();
    actAs(member);
    const own = await (await collection.POST(json("POST", { kind: "anthropic_oauth", token: OAUTH_TOKEN }))).json();

    const patched = await single.PATCH(json("PATCH", { label: "mine", state: "disabled" }), params(own.account.id));
    expect(patched.status).toBe(200);
    expect((await patched.json()).account).toMatchObject({ label: "mine", state: "disabled" });

    // A shared account is visible to the member, so the refusal explains itself.
    await expectPermissionRequired(
      await single.PATCH(json("PATCH", { label: "hijacked" }), params(shared.account.id)),
      "change_shared_account",
      ["ask_admin"],
    );
    await expectPermissionRequired(await single.DELETE(del(), params(shared.account.id)), "change_shared_account", ["ask_admin"]);
    expect(store.rows.get(shared.account.id)).toMatchObject({ label: "", state: "active" });

    // Someone else's private account does not exist for the member.
    expect((await single.PATCH(json("PATCH", { label: "x" }), params(adminPrivate.account.id))).status).toBe(404);
    expect((await single.DELETE(del(), params(adminPrivate.account.id))).status).toBe(404);
    expect((await single.DELETE(del(), params("00000000-0000-4000-8000-00000000ffff"))).status).toBe(404);
    expect(store.rows.has(adminPrivate.account.id)).toBe(true);

    const removed = await single.DELETE(del(), params(own.account.id));
    expect(removed.status).toBe(200);
    expect(await removed.json()).toEqual({ removed: true, count: 1 });
    expect(store.rows.has(own.account.id)).toBe(false);
  });

  test("removing every team account needs account administration", async () => {
    const { collection, store, actAs } = handlers();
    await collection.POST(json("POST", { kind: "anthropic_api_key", apiKey: API_KEY, visibility: "team" }));
    actAs(member);
    await collection.POST(json("POST", { kind: "anthropic_oauth", token: OAUTH_TOKEN }));
    await expectPermissionRequired(await collection.DELETE(del()), "remove_all_accounts", ["ask_admin"]);
    expect(store.rows.size).toBe(2);
  });

  test("a VM token still imports team-visible accounts", async () => {
    const { collection, store, actAs } = handlers();
    actAs(vm);
    const response = await collection.POST(json("POST", { kind: "anthropic_oauth", token: OAUTH_TOKEN, visibility: "private" }));
    expect(response.status).toBe(201);
    const body = await response.json();
    expect(store.rows.get(body.account.id)).toMatchObject({ createdBy: "user_1", visibility: "team" });
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
