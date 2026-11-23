import { describe, expect, mock, test } from "bun:test";
import { randomBytes } from "node:crypto";
import {
  createClaudeUpstreamService,
  type ClaudeAccountRow,
  type ClaudeAccountStore,
  type ClaudeUpstream,
} from "../services/coderouter/claudeUpstream";
import {
  claudeFallbackConfig,
  createClaudeFallbackSpend,
  FALLBACK_ACCOUNT_ENV,
  FALLBACK_CAP_ENV,
  UNPRICED_USD_PER_TOKEN,
  type ClaudeFallbackConfig,
} from "../services/coderouter/claudeFallback";
import type { CredentialKeyService } from "../services/coderouter/encryption";
import { createClaudeMessagesProxy, type ClaudeProxyDependencies } from "../services/coderouter/claudeProxy";
import { INCLUDED_USAGE_USED_UP_MESSAGE } from "../services/coderouter/noAccountMessage";
import { classifyCoderouterFault } from "../services/coderouter/faultClassification";
import { makeAgentAccessHandler } from "../app/api/coderouter/agent-access/route";

const API_KEY = "sk-ant-api03-abcdefghijklmnopqrstuvwxyz0123456789";
const API_KEY_2 = "sk-ant-api03-zyxwvutsrqponmlkjihgfedcba9876543210";
const T0 = new Date("2026-11-23T10:00:00.000Z");
const PLATFORM = "platform-team";
const NEWCOMER = "newcomer-team";
const vmAccess = { kind: "vm" as const, vmId: "vm-1", poolId: "pool-1" };

function fakeKeys(): CredentialKeyService {
  const dataKey = randomBytes(32);
  return {
    async generateDataKey() {
      return { plaintext: Buffer.from(dataKey), encrypted: Buffer.from(dataKey) };
    },
    async decryptDataKey() {
      return Buffer.from(dataKey);
    },
  };
}

/** Rows are visible to a caller only on its own team, and `hidden` rows to nobody (an ungranted pool). */
function memoryStore(): ClaudeAccountStore & { rows: Map<string, ClaudeAccountRow>; hidden: Set<string> } {
  const rows = new Map<string, ClaudeAccountRow>();
  const hidden = new Set<string>();
  let tick = 0;
  return {
    rows,
    hidden,
    async list(teamId) {
      return [...rows.values()].filter((row) => row.teamId === teamId && !hidden.has(row.id));
    },
    async insert(row) {
      const createdAt = new Date(T0.getTime() + tick++);
      const written = { ...row, createdAt, updatedAt: createdAt };
      rows.set(row.id, written);
      return written;
    },
    async update() {
      return null;
    },
    async remove() {
      return false;
    },
    async removeAll() {
      return 0;
    },
    async markCooldown() {},
    async touchUsed() {},
  };
}

function setup(options: { config?: ClaudeFallbackConfig; spent?: number | null; withFallbackDeps?: boolean } = {}) {
  const store = memoryStore();
  let counter = 0;
  const keys = fakeKeys();
  const newId = () => `00000000-0000-4000-8000-${String(++counter).padStart(12, "0")}`;
  const plain = createClaudeUpstreamService({ store, keys, keyId: "kms-test", now: () => T0, newId });
  const spentUsd = mock(async () => (options.spent === undefined ? 0 : options.spent));
  const loadAccount = mock(async (id: string) => store.rows.get(id) ?? null);
  const teamHasAnyAccount = mock(async (teamId: string) => [...store.rows.values()].some((row) => row.teamId === teamId));
  let config: ClaudeFallbackConfig = options.config ?? { kind: "off" };
  const service = createClaudeUpstreamService({
    store,
    keys,
    keyId: "kms-test",
    now: () => T0,
    newId,
    ...(options.withFallbackDeps === false ? {} : {
      fallback: {
        config: () => config,
        teamHasAnyAccount,
        loadAccount,
        spend: { spentUsd, note: () => {} },
      },
    }),
  });
  return {
    store,
    service,
    plain,
    spentUsd,
    loadAccount,
    teamHasAnyAccount,
    setConfig: (next: ClaudeFallbackConfig) => {
      config = next;
    },
  };
}

async function withFallbackAccount(options: Parameters<typeof setup>[0] = {}) {
  const ctx = setup(options);
  const fallback = await ctx.plain.add(PLATFORM, "ops", { kind: "anthropic_api_key", apiKey: API_KEY }, "team");
  const on: ClaudeFallbackConfig = { kind: "on", accountId: fallback.id, capUsd: 1 };
  if (!options.config) ctx.setConfig(on);
  return { ...ctx, fallbackId: fallback.id, on };
}

describe("claude fallback config", () => {
  test("off unless the id is set; an id without a positive cap is refused", () => {
    const id = "00000000-0000-4000-8000-0000000000aa";
    expect(claudeFallbackConfig({})).toEqual({ kind: "off" });
    expect(claudeFallbackConfig({ [FALLBACK_CAP_ENV]: "1" })).toEqual({ kind: "off" });
    expect(claudeFallbackConfig({ [FALLBACK_ACCOUNT_ENV]: id })).toEqual({ kind: "refused" });
    expect(claudeFallbackConfig({ [FALLBACK_ACCOUNT_ENV]: id, [FALLBACK_CAP_ENV]: "0" })).toEqual({ kind: "refused" });
    expect(claudeFallbackConfig({ [FALLBACK_ACCOUNT_ENV]: id, [FALLBACK_CAP_ENV]: "-1" })).toEqual({ kind: "refused" });
    expect(claudeFallbackConfig({ [FALLBACK_ACCOUNT_ENV]: id, [FALLBACK_CAP_ENV]: "one" })).toEqual({ kind: "refused" });
    expect(claudeFallbackConfig({ [FALLBACK_ACCOUNT_ENV]: "not-a-uuid", [FALLBACK_CAP_ENV]: "1" })).toEqual({ kind: "refused" });
    expect(claudeFallbackConfig({ [FALLBACK_ACCOUNT_ENV]: id, [FALLBACK_CAP_ENV]: "1.5" }))
      .toEqual({ kind: "on", accountId: id, capUsd: 1.5 });
  });
});

describe("claude fallback selection", () => {
  test("unset env: a team with no accounts gets exactly today's answer, and nothing else is read", async () => {
    const { service, plain, setConfig, spentUsd, loadAccount, teamHasAnyAccount } = await withFallbackAccount();
    setConfig({ kind: "off" });
    const input = { access: vmAccess, stickyKey: "vm-1" };
    expect(await service.select(NEWCOMER, input)).toEqual({ kind: "none" });
    expect(await plain.select(NEWCOMER, input)).toEqual({ kind: "none" });
    expect(await service.hasActive(NEWCOMER, vmAccess)).toBe(false);
    expect(teamHasAnyAccount).not.toHaveBeenCalled();
    expect(spentUsd).not.toHaveBeenCalled();
    expect(loadAccount).not.toHaveBeenCalled();
  });

  test("set, no accounts, under the cap: the fallback account serves the caller's team", async () => {
    const { service, fallbackId, spentUsd } = await withFallbackAccount({ spent: 0.4 });
    const selection = await service.select(NEWCOMER, { access: vmAccess, stickyKey: "vm-1" });
    expect(selection.kind).toBe("selected");
    const upstream = (selection as { upstream: ClaudeUpstream }).upstream;
    expect(upstream.accountId).toBe(fallbackId);
    expect(upstream.fallback).toBe(true);
    expect(upstream.secret).toEqual({ kind: "anthropic_api_key", apiKey: API_KEY });
    expect(spentUsd).toHaveBeenCalledWith(NEWCOMER, fallbackId, undefined);
    expect(await service.hasActive(NEWCOMER, vmAccess)).toBe(true);
  });

  test("at or over the cap: refused with the capped answer, and agent access reports no Claude", async () => {
    for (const spent of [1, 3.2]) {
      const { service, loadAccount } = await withFallbackAccount({ spent });
      expect(await service.select(NEWCOMER, { access: vmAccess, stickyKey: "vm-1" })).toEqual({ kind: "fallback_capped" });
      expect(await service.hasActive(NEWCOMER, vmAccess)).toBe(false);
      expect(loadAccount).not.toHaveBeenCalled();
    }
  });

  test("an id with no cap is refused: today's answer", async () => {
    const { service, spentUsd, loadAccount } = await withFallbackAccount({ config: { kind: "refused" } });
    expect(await service.select(NEWCOMER, { access: vmAccess, stickyKey: "vm-1" })).toEqual({ kind: "none" });
    expect(await service.hasActive(NEWCOMER, vmAccess)).toBe(false);
    expect(spentUsd).not.toHaveBeenCalled();
    expect(loadAccount).not.toHaveBeenCalled();
  });

  test("a ledger that cannot answer refuses the fallback (fail closed)", async () => {
    const { service } = await withFallbackAccount({ spent: null });
    expect(await service.select(NEWCOMER, { access: vmAccess, stickyKey: "vm-1" })).toEqual({ kind: "fallback_unavailable" });
    expect(await service.hasActive(NEWCOMER, vmAccess)).toBe(false);
  });

  test("a team with its own accounts never touches the fallback, even ones this caller cannot see", async () => {
    const { service, plain, store, spentUsd, loadAccount } = await withFallbackAccount();
    const own = await plain.add(NEWCOMER, "user-1", { kind: "anthropic_api_key", apiKey: API_KEY_2 }, "team");
    const selection = await service.select(NEWCOMER, { access: vmAccess, stickyKey: "vm-1" });
    expect((selection as { upstream: ClaudeUpstream }).upstream.accountId).toBe(own.id);
    expect((selection as { upstream: ClaudeUpstream }).upstream.fallback).toBeUndefined();
    // Disabled: the team's own exhausted answer, not the fallback.
    store.rows.set(own.id, { ...store.rows.get(own.id)!, state: "disabled" });
    expect((await service.select(NEWCOMER, { access: vmAccess, stickyKey: "vm-1" })).kind).toBe("exhausted");
    expect(await service.hasActive(NEWCOMER, vmAccess)).toBe(false);
    // Not granted to this machine's pool: still the team's own "none".
    store.rows.set(own.id, { ...store.rows.get(own.id)!, state: "active" });
    store.hidden.add(own.id);
    expect(await service.select(NEWCOMER, { access: vmAccess, stickyKey: "vm-1" })).toEqual({ kind: "none" });
    expect(await service.hasActive(NEWCOMER, vmAccess)).toBe(false);
    expect(spentUsd).not.toHaveBeenCalled();
    expect(loadAccount).not.toHaveBeenCalled();
  });

  test("only the configured id crosses teams: another team's account stays out of reach", async () => {
    const { service, plain, store, setConfig, on, loadAccount } = await withFallbackAccount();
    const foreign = await plain.add("other-team", "someone", { kind: "anthropic_api_key", apiKey: API_KEY_2 }, "team");
    // The caller excluding or naming another id never reaches it: select reads only the configured id.
    const selection = await service.select(NEWCOMER, { access: vmAccess, stickyKey: "vm-1" });
    expect((selection as { upstream: ClaudeUpstream }).upstream.accountId).toBe(on.accountId);
    expect(loadAccount.mock.calls.map((call) => call[0])).toEqual([on.accountId]);
    // A config naming an id whose row is a different account (or none) serves nothing.
    loadAccount.mockImplementation(async () => store.rows.get(foreign.id) ?? null);
    expect(await service.select(NEWCOMER, { access: vmAccess, stickyKey: "vm-1" })).toEqual({ kind: "none" });
    loadAccount.mockImplementation(async (id: string) => store.rows.get(id) ?? null);
    setConfig({ kind: "on", accountId: "00000000-0000-4000-8000-0000000000ff", capUsd: 1 });
    expect(await service.select(NEWCOMER, { access: vmAccess, stickyKey: "vm-1" })).toEqual({ kind: "none" });
    // The foreign team's own listing for the newcomer stays empty.
    expect(await plain.list(NEWCOMER, vmAccess)).toEqual([]);
  });

  test("a tried or disabled fallback account is exhausted, not reused", async () => {
    const { service, store, fallbackId } = await withFallbackAccount();
    const tried = await service.select(NEWCOMER, { access: vmAccess, stickyKey: "vm-1", excludedAccountIds: [fallbackId] });
    expect(tried.kind).toBe("exhausted");
    store.rows.set(fallbackId, { ...store.rows.get(fallbackId)!, state: "disabled" });
    expect(await service.hasActive(NEWCOMER, vmAccess)).toBe(false);
  });
});

describe("claude fallback spend cache", () => {
  test("one ledger read per team per window; local completions add to it", async () => {
    let clock = 0;
    const read = mock(async () => 0.25);
    const spend = createClaudeFallbackSpend({ read, now: () => clock, ttlMs: 60_000 });
    expect(await spend.spentUsd("t", "a")).toBe(0.25);
    spend.note("t", "a", 0.5);
    expect(await spend.spentUsd("t", "a")).toBe(0.75);
    clock = 59_999;
    expect(await spend.spentUsd("t", "a")).toBe(0.75);
    expect(read).toHaveBeenCalledTimes(1);
    // After the window, the ledger answer replaces it, but never lowers it.
    clock = 60_000;
    expect(await spend.spentUsd("t", "a")).toBe(0.75);
    read.mockImplementation(async () => 2);
    clock = 120_000;
    expect(await spend.spentUsd("t", "a")).toBe(2);
    expect(read).toHaveBeenCalledTimes(3);
  });

  test("concurrent requests share one read, and a failed read is not cached", async () => {
    let calls = 0;
    const spend = createClaudeFallbackSpend({
      read: async () => {
        calls += 1;
        return calls === 1 ? null : 0.1;
      },
    });
    expect(await spend.spentUsd("t", "a")).toBeNull();
    const [a, b] = await Promise.all([spend.spentUsd("t", "a"), spend.spentUsd("t", "a")]);
    expect([a, b]).toEqual([0.1, 0.1]);
    expect(calls).toBe(2);
  });

  test("the ledger read is one team-scoped sum, and unpriced tokens are charged", async () => {
    const bodies: string[] = [];
    const urls: string[] = [];
    const spend = createClaudeFallbackSpend({
      clickhouse: {
        config: () => ({ url: "https://ch.example", user: "u", password: "p", database: "coderouter" }),
        fetch: (async (url: URL, init: RequestInit) => {
          urls.push(String(url));
          bodies.push(String(init.body));
          return new Response(`{"usd":0.5,"unpriced_tokens":40000}\n`);
        }) as never,
      } as never,
    });
    expect(await spend.spentUsd("team-x", "acct-y")).toBeCloseTo(0.5 + 40_000 * UNPRICED_USD_PER_TOKEN, 9);
    expect(bodies[0]).toContain("FROM coderouter.usage_events");
    expect(bodies[0]).toContain("team_id = {team_id:String}");
    expect(bodies[0]).toContain("upstream_account_id = {account_id:String}");
    expect(urls[0]).toContain("param_team_id=team-x");
    expect(urls[0]).toContain("param_account_id=acct-y");
  });
});

describe("claude fallback through the proxy", () => {
  function proxy(selection: Awaited<ReturnType<ClaudeProxyDependencies["select"]>>, fetched: string[]) {
    return createClaudeMessagesProxy({
      authenticate: async () => ({ ok: true, identity: { teamId: NEWCOMER, stackUserId: "user-1", vmId: "vm-1", token: "crt_x" } }),
      select: async () => selection,
      cooldown: async () => {},
      touchUsed: async () => {},
      fetch: (async (input: string | URL | Request) => {
        fetched.push(String(input));
        return Response.json({ id: "msg_1", type: "message", model: "claude-sonnet-5", usage: { input_tokens: 1, output_tokens: 1 } });
      }) as typeof fetch,
      now: () => T0,
      capture: () => {},
      fallbackSpend: { spentUsd: async () => 0, note: () => {} },
    }, { now: () => 0, sleep: async () => {}, random: () => 0 });
  }
  const request = () => new Request("https://coderouter.dev/v1/messages", {
    method: "POST",
    headers: { "content-type": "application/json", authorization: "Bearer crt_x" },
    body: JSON.stringify({ model: "claude-sonnet-5", max_tokens: 8, messages: [{ role: "user", content: "hi" }] }),
  });

  test("over the cap: a distinct non-retryable refusal in plain words, before anything is forwarded", async () => {
    const fetched: string[] = [];
    const response = await proxy({ kind: "fallback_capped" }, fetched)(request());
    expect(response.status).toBe(403);
    const body = await response.json();
    expect(body).toEqual({ type: "error", error: { type: "permission_error", message: INCLUDED_USAGE_USED_UP_MESSAGE } });
    expect(response.headers.get("retry-after")).toBeNull();
    expect(fetched).toEqual([]);
    expect(INCLUDED_USAGE_USED_UP_MESSAGE).toContain("used up");
    expect(INCLUDED_USAGE_USED_UP_MESSAGE).toContain("sign in to Claude");
    expect(INCLUDED_USAGE_USED_UP_MESSAGE).toContain("add credits");
    expect(INCLUDED_USAGE_USED_UP_MESSAGE).not.toMatch(/coderouter|anthropic|bedrock|aws|fallback|upstream/i);
    expect(classifyCoderouterFault({ outcome: "no_usable_account", failureStage: "usage_cap", status: 403 } as never)).toBe("tenant");
  });

  test("an unreadable ledger is a retryable 503, nothing forwarded", async () => {
    const fetched: string[] = [];
    const response = await proxy({ kind: "fallback_unavailable" }, fetched)(request());
    expect(response.status).toBe(503);
    expect(response.headers.get("retry-after")).toBe("5");
    expect(fetched).toEqual([]);
  });

  test("under the cap: forwarded with the fallback account's credential", async () => {
    const fetched: string[] = [];
    const upstream: ClaudeUpstream = {
      accountId: "00000000-0000-4000-8000-0000000000aa",
      teamId: PLATFORM,
      kind: "anthropic_api_key",
      label: "",
      secret: { kind: "anthropic_api_key", apiKey: API_KEY },
      config: {},
      updatedAt: T0,
      fallback: true,
    };
    const response = await proxy({ kind: "selected", upstream, total: 1, healthy: 1 }, fetched)(request());
    expect(response.status).toBe(200);
    expect(fetched).toEqual(["https://api.anthropic.com/v1/messages"]);
  });
});

describe("agent access with the fallback", () => {
  test("reports Claude available exactly when the fallback applies and the team is under the cap", async () => {
    for (const [spent, expected] of [[0, true], [1, false]] as const) {
      const { service } = await withFallbackAccount({ spent });
      const GET = makeAgentAccessHandler({
        resolveUsageTeam: (async () => ({ ok: true, teamId: NEWCOMER, stackUserId: "user-1", access: vmAccess })) as never,
        hasActiveClaude: service.hasActive,
        hasConfigured: (async () => false) as never,
      });
      const body = await (await GET(new Request("https://cmux.com/api/coderouter/agent-access"))).json();
      expect(body.agents.claude).toBe(expected);
    }
  });
});
