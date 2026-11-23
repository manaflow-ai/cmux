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
  createFallbackPlanReader,
  fallbackReservationCents,
  fallbackCapCents,
  fallbackModelAllowed,
  FALLBACK_ACCOUNT_ENV,
  GLOBAL_DAILY_BUDGET_CENTS,
  INCLUDED_USAGE_NOTICE,
  UNPRICED_USD_PER_TOKEN,
  type ClaudeFallbackConfig,
} from "../services/coderouter/claudeFallback";
import type { CredentialKeyService } from "../services/coderouter/encryption";
import { createClaudeMessagesProxy, type ClaudeProxyDependencies } from "../services/coderouter/claudeProxy";
import { FALLBACK_REFUSAL_MESSAGES } from "../services/coderouter/noAccountMessage";
import { classifyCoderouterFault } from "../services/coderouter/faultClassification";
import { DeliveredClaudeUsage } from "../services/coderouter/claudeUsage";
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

type SetupOptions = {
  config?: ClaudeFallbackConfig;
  /** Cents the team has used; null = the ledger cannot answer. */
  spent?: number | null;
  /** Cents every team used today; null = the ledger cannot answer. */
  today?: number | null;
  plan?: string | null;
  /** Drives the real cached plan reader instead of a fixed plan. */
  planReader?: ReturnType<typeof createFallbackPlanReader>;
};

function setup(options: SetupOptions = {}) {
  const store = memoryStore();
  let counter = 0;
  const keys = fakeKeys();
  const newId = () => `00000000-0000-4000-8000-${String(++counter).padStart(12, "0")}`;
  const plain = createClaudeUpstreamService({ store, keys, keyId: "kms-test", now: () => T0, newId });
  const teamCents = mock(async () => (options.spent === undefined ? 0 : options.spent));
  const todayCents = mock(async () => (options.today === undefined ? 0 : options.today));
  const loadAccount = mock(async (id: string) => store.rows.get(id) ?? null);
  const teamHasAnyAccount = mock(async (teamId: string) => [...store.rows.values()].some((row) => row.teamId === teamId));
  const planId = mock(options.planReader ??
    (async () => ({ kind: "plan" as const, planId: options.plan === undefined ? "next_intro" : options.plan })));
  let config: ClaudeFallbackConfig = options.config ?? { kind: "off" };
  // The real in-flight holds; the ledger reads are the mocks above.
  const spend = { ...createClaudeFallbackSpend(), teamCents, todayCents, note: () => {} };
  const service = createClaudeUpstreamService({
    store,
    keys,
    keyId: "kms-test",
    now: () => T0,
    newId,
    fallback: {
      config: () => config,
      teamHasAnyAccount,
      planId,
      loadAccount,
      spend,
    },
  });
  return {
    store,
    service,
    spend,
    plain,
    teamCents,
    todayCents,
    planId,
    loadAccount,
    teamHasAnyAccount,
    setConfig: (next: ClaudeFallbackConfig) => {
      config = next;
    },
  };
}

async function withFallbackAccount(options: SetupOptions = {}) {
  const ctx = setup(options);
  const fallback = await ctx.plain.add(PLATFORM, "ops", { kind: "anthropic_api_key", apiKey: API_KEY }, "team");
  const on: ClaudeFallbackConfig = { kind: "on", accountId: fallback.id };
  if (!options.config) ctx.setConfig(on);
  return { ...ctx, fallbackId: fallback.id, on };
}

const sonnet = () => "claude-sonnet-5";
const opus = () => "claude-opus-4-8";
const pick = (model: () => string | null = sonnet) => ({ access: vmAccess, stickyKey: "vm-1", model });

describe("house route config, plan cap and model tier", () => {
  test("off unless the id is set to an account id", () => {
    const id = "00000000-0000-4000-8000-0000000000AA";
    expect(claudeFallbackConfig({})).toEqual({ kind: "off" });
    expect(claudeFallbackConfig({ [FALLBACK_ACCOUNT_ENV]: "" })).toEqual({ kind: "off" });
    expect(claudeFallbackConfig({ [FALLBACK_ACCOUNT_ENV]: "not-a-uuid" })).toEqual({ kind: "off" });
    expect(claudeFallbackConfig({ [FALLBACK_ACCOUNT_ENV]: id })).toEqual({ kind: "on", accountId: id.toLowerCase() });
  });

  test("the plan picks the cap in cents; every other plan gets none", () => {
    expect(fallbackCapCents("next_intro")).toBe(500);
    expect(fallbackCapCents("next_taste")).toBe(50);
    for (const plan of ["pro", "go", "free", "", null, undefined, "next_intro_x"]) expect(fallbackCapCents(plan)).toBe(0);
    expect(GLOBAL_DAILY_BUDGET_CENTS).toBe(10_000);
  });

  test("Sonnet tier and below only", () => {
    for (const model of ["claude-sonnet-5", "claude-sonnet-4-6", "claude-haiku-4-5-20251001", "claude-3-5-haiku-20241022", "claude-3-7-sonnet-latest"]) {
      expect(fallbackModelAllowed(model)).toBe(true);
    }
    for (const model of ["claude-opus-4-8", "claude-opus-5", "claude-3-opus-20240229", "gpt-5", "", null]) {
      expect(fallbackModelAllowed(model)).toBe(false);
    }
  });
});

describe("house route selection", () => {
  test("unset env: a team with no accounts gets exactly today's answer, and nothing else is read", async () => {
    const { service, plain, setConfig, teamCents, loadAccount, teamHasAnyAccount, planId } = await withFallbackAccount();
    setConfig({ kind: "off" });
    expect(await service.select(NEWCOMER, pick())).toEqual({ kind: "none" });
    expect(await plain.select(NEWCOMER, pick())).toEqual({ kind: "none" });
    expect(await service.hasActive(NEWCOMER, vmAccess)).toBe(false);
    for (const read of [teamHasAnyAccount, planId, teamCents, loadAccount]) expect(read).not.toHaveBeenCalled();
  });

  test("no-account team under the cap: the house account serves it, tagged, with its usage", async () => {
    const { service, fallbackId, teamCents } = await withFallbackAccount({ spent: 120 });
    const selection = await service.select(NEWCOMER, pick());
    expect(selection.kind).toBe("selected");
    const selected = selection as { upstream: ClaudeUpstream; included?: unknown };
    expect(selected.upstream.accountId).toBe(fallbackId);
    expect(selected.upstream.fallback).toBe(true);
    expect(selected.upstream.secret).toEqual({ kind: "anthropic_api_key", apiKey: API_KEY });
    expect(selected.included).toEqual({ spentCents: 120, capCents: 500 });
    expect(teamCents).toHaveBeenCalledWith(NEWCOMER, fallbackId, undefined);
    expect(await service.hasActive(NEWCOMER, vmAccess)).toBe(true);
  });

  test("at or over the cap: refused as used up, before the account is read", async () => {
    for (const [plan, spent] of [["next_intro", 500], ["next_intro", 731], ["next_taste", 50]] as const) {
      const { service, loadAccount } = await withFallbackAccount({ plan, spent });
      expect(await service.select(NEWCOMER, pick())).toEqual({ kind: "fallback_refused", reason: "included_usage_used_up" });
      expect(await service.hasActive(NEWCOMER, vmAccess)).toBe(false);
      expect(loadAccount).not.toHaveBeenCalled();
    }
  });

  test("a plan with no included usage, or no plan the router can read, gets today's answer", async () => {
    for (const plan of ["pro", null]) {
      const { service, teamCents } = await withFallbackAccount({ plan });
      expect(await service.select(NEWCOMER, pick())).toEqual({ kind: "none" });
      expect(await service.hasActive(NEWCOMER, vmAccess)).toBe(false);
      expect(teamCents).not.toHaveBeenCalled();
    }
  });

  test("a usage read that fails refuses (fail closed)", async () => {
    const { service } = await withFallbackAccount({ spent: null });
    expect(await service.select(NEWCOMER, pick())).toEqual({ kind: "fallback_unavailable" });
    expect(await service.hasActive(NEWCOMER, vmAccess)).toBe(false);
    const taste = await withFallbackAccount({ plan: "next_taste", today: null });
    expect(await taste.service.select(NEWCOMER, pick())).toEqual({ kind: "fallback_unavailable" });
  });

  test("tastes share one daily budget; the intro plan does not draw on it", async () => {
    const taste = await withFallbackAccount({ plan: "next_taste", spent: 10, today: GLOBAL_DAILY_BUDGET_CENTS });
    expect(await taste.service.select(NEWCOMER, pick())).toEqual({ kind: "fallback_refused", reason: "included_daily_budget_reached" });
    expect(await taste.service.hasActive(NEWCOMER, vmAccess)).toBe(false);
    const under = await withFallbackAccount({ plan: "next_taste", spent: 10, today: GLOBAL_DAILY_BUDGET_CENTS - 1 });
    expect((await under.service.select(NEWCOMER, pick())).kind).toBe("selected");
    const intro = await withFallbackAccount({ plan: "next_intro", today: GLOBAL_DAILY_BUDGET_CENTS * 2 });
    expect((await intro.service.select(NEWCOMER, pick())).kind).toBe("selected");
    expect(intro.todayCents).not.toHaveBeenCalled();
  });

  test("a tier above Sonnet gets the sign-in step, never a silent downgrade", async () => {
    const { service, teamCents, loadAccount } = await withFallbackAccount();
    expect(await service.select(NEWCOMER, pick(opus))).toEqual({ kind: "fallback_refused", reason: "model_not_included" });
    expect(await service.select(NEWCOMER, pick(() => null))).toEqual({ kind: "fallback_refused", reason: "model_not_included" });
    expect(teamCents).not.toHaveBeenCalled();
    expect(loadAccount).not.toHaveBeenCalled();
    // The model list names no model and is served.
    expect((await service.select(NEWCOMER, { access: vmAccess, stickyKey: "vm-1" })).kind).toBe("selected");
  });

  test("a team with its own account is untouched, even one this caller cannot see", async () => {
    const { service, plain, store, teamCents, loadAccount, planId } = await withFallbackAccount();
    const own = await plain.add(NEWCOMER, "user-1", { kind: "anthropic_api_key", apiKey: API_KEY_2 }, "team");
    const selection = await service.select(NEWCOMER, pick(opus));
    expect((selection as { upstream: ClaudeUpstream }).upstream.accountId).toBe(own.id);
    expect((selection as { upstream: ClaudeUpstream }).upstream.fallback).toBeUndefined();
    expect((selection as { included?: unknown }).included).toBeUndefined();
    // Disabled: the team's own exhausted answer, never the house route.
    store.rows.set(own.id, { ...store.rows.get(own.id)!, state: "disabled" });
    expect((await service.select(NEWCOMER, pick())).kind).toBe("exhausted");
    expect(await service.hasActive(NEWCOMER, vmAccess)).toBe(false);
    // Not granted to this machine's pool: still the team's own "none".
    store.rows.set(own.id, { ...store.rows.get(own.id)!, state: "active" });
    store.hidden.add(own.id);
    expect(await service.select(NEWCOMER, pick())).toEqual({ kind: "none" });
    expect(await service.hasActive(NEWCOMER, vmAccess)).toBe(false);
    for (const read of [planId, teamCents, loadAccount]) expect(read).not.toHaveBeenCalled();
  });

  test("only the configured id crosses teams: another team's account stays out of reach", async () => {
    const { service, plain, store, setConfig, on, loadAccount } = await withFallbackAccount();
    const foreign = await plain.add("other-team", "someone", { kind: "anthropic_api_key", apiKey: API_KEY_2 }, "team");
    const selection = await service.select(NEWCOMER, pick());
    expect((selection as { upstream: ClaudeUpstream }).upstream.accountId).toBe((on as { accountId: string }).accountId);
    expect(loadAccount.mock.calls.map((call) => call[0])).toEqual([(on as { accountId: string }).accountId]);
    // A load that returns any other row serves nothing.
    loadAccount.mockImplementation(async () => store.rows.get(foreign.id) ?? null);
    expect(await service.select(NEWCOMER, pick())).toEqual({ kind: "none" });
    loadAccount.mockImplementation(async (id: string) => store.rows.get(id) ?? null);
    // An id with no row serves nothing.
    setConfig({ kind: "on", accountId: "00000000-0000-4000-8000-0000000000ff" });
    expect(await service.select(NEWCOMER, pick())).toEqual({ kind: "none" });
    expect(await plain.list(NEWCOMER, vmAccess)).toEqual([]);
  });

  test("a tried or disabled house account is exhausted, not reused", async () => {
    const { service, store, fallbackId } = await withFallbackAccount();
    expect((await service.select(NEWCOMER, { ...pick(), excludedAccountIds: [fallbackId] })).kind).toBe("exhausted");
    store.rows.set(fallbackId, { ...store.rows.get(fallbackId)!, state: "disabled" });
    expect(await service.hasActive(NEWCOMER, vmAccess)).toBe(false);
  });
});

describe("house route plan from the sign-in record", () => {
  const VM = "00000000-0000-4000-8000-00000000f00d";
  const BUYER = "buyer-user";
  const machine = { kind: "vm" as const, vmId: VM, poolId: "pool-1" };
  const DAY = 24 * 60 * 60 * 1000;
  const future = new Date(T0.getTime() + 7 * DAY).toISOString();
  const past = new Date(T0.getTime() - 1).toISOString();
  type Readers = { metadata?: unknown; vmUser?: string | null; failVm?: boolean; failUser?: boolean; clock?: () => number };
  function reader(readers: Readers = {}) {
    const readVmUser = mock(async (caller: { teamId: string; vmId: string }) => {
      if (readers.failVm) throw new Error("db down");
      return caller.teamId === NEWCOMER && caller.vmId === VM ? (readers.vmUser === undefined ? BUYER : readers.vmUser) : null;
    });
    const readUserMetadata = mock(async (userId: string) => {
      if (readers.failUser) throw new Error("stack down");
      return userId === BUYER ? readers.metadata : null;
    });
    const read = createFallbackPlanReader({ readVmUser, readUserMetadata, now: readers.clock ?? (() => T0.getTime()) });
    return { read, readVmUser, readUserMetadata };
  }
  const meta = (plan: unknown, endsAt?: unknown) => ({
    cmuxPlan: "free",
    cmuxNextPlan: plan,
    cmuxNextPlanStartedAt: T0.toISOString(),
    ...(endsAt === undefined ? {} : { cmuxNextPlanEndsAt: endsAt }),
  });
  const select = (service: { select: (teamId: string, input: never) => Promise<unknown> }) =>
    service.select(NEWCOMER, { access: machine, stickyKey: VM, model: sonnet } as never);

  test("next_intro with an end ahead: cap 500", async () => {
    const { read, readUserMetadata } = reader({ metadata: meta("next_intro", future) });
    const { service } = await withFallbackAccount({ planReader: read, spent: 10 });
    expect(await select(service)).toMatchObject({ kind: "selected", included: { spentCents: 10, capCents: 500 } });
    expect(readUserMetadata).toHaveBeenCalledWith(BUYER);
  });

  test("next_taste with an end ahead: cap 50", async () => {
    const { read } = reader({ metadata: meta("next_taste", future) });
    const { service } = await withFallbackAccount({ planReader: read, spent: 10 });
    expect(await select(service)).toMatchObject({ kind: "selected", included: { spentCents: 10, capCents: 50 } });
  });

  test("an end that has passed, a missing or unparseable end, or no plan: cap 0, today's answer", async () => {
    for (const metadata of [meta("next_intro", past), meta("next_intro"), meta("next_intro", "not a date"), meta("next_intro", 12), meta(undefined, future), {}, null]) {
      const { read } = reader({ metadata });
      const { service, teamCents } = await withFallbackAccount({ planReader: read });
      expect(await select(service)).toEqual({ kind: "none" });
      expect(teamCents).not.toHaveBeenCalled();
    }
    // Not the team's machine, or a machine with no creator: no record is read.
    for (const vmUser of [null, ""]) {
      const { read, readUserMetadata } = reader({ metadata: meta("next_intro", future), vmUser });
      const { service } = await withFallbackAccount({ planReader: read });
      expect(await select(service)).toEqual({ kind: "none" });
      expect(readUserMetadata).not.toHaveBeenCalled();
    }
  });

  test("a read that fails refuses (fail closed, 503) and is not cached", async () => {
    for (const failure of [{ failVm: true }, { failUser: true }]) {
      const readers = reader({ metadata: meta("next_intro", future), ...failure });
      const { service, teamCents } = await withFallbackAccount({ planReader: readers.read });
      expect(await select(service)).toEqual({ kind: "fallback_unavailable" });
      expect(teamCents).not.toHaveBeenCalled();
      await select(service);
      expect(readers.readVmUser).toHaveBeenCalledTimes(2);
    }
  });

  test("env unset: the plan reader runs no read", async () => {
    const { read, readVmUser, readUserMetadata } = reader({ metadata: meta("next_intro", future) });
    const { service, setConfig } = await withFallbackAccount({ planReader: read });
    setConfig({ kind: "off" });
    expect(await select(service)).toEqual({ kind: "none" });
    expect(await service.hasActive(NEWCOMER, machine)).toBe(false);
    expect(readVmUser).not.toHaveBeenCalled();
    expect(readUserMetadata).not.toHaveBeenCalled();
  });

  test("one read per machine per 60 s window, never past the pass's own end", async () => {
    let clock = T0.getTime();
    const endsAt = new Date(T0.getTime() + 30_000).toISOString();
    const { read, readVmUser, readUserMetadata } = reader({ metadata: meta("next_intro", endsAt), clock: () => clock });
    const caller = { teamId: NEWCOMER, vmId: VM };
    expect(await Promise.all([read(caller), read(caller)])).toEqual([
      { kind: "plan", planId: "next_intro" },
      { kind: "plan", planId: "next_intro" },
    ]);
    clock += 29_999;
    expect(await read(caller)).toEqual({ kind: "plan", planId: "next_intro" });
    clock += 1;
    expect(await read(caller)).toEqual({ kind: "plan", planId: null });
    expect(readVmUser).toHaveBeenCalledTimes(1);
    expect(readUserMetadata).toHaveBeenCalledTimes(1);
    clock += 30_000;
    expect(await read(caller)).toEqual({ kind: "plan", planId: null });
    expect(readVmUser).toHaveBeenCalledTimes(2);
    // A caller that is not a Cloud machine has no plan and reads nothing.
    expect(await read({ teamId: NEWCOMER, vmId: null })).toEqual({ kind: "plan", planId: null });
    expect(readVmUser).toHaveBeenCalledTimes(2);
  });
});

describe("house route spend", () => {
  test("one ledger read per team per window; local completions add to it, and it never drops", async () => {
    let clock = 0;
    const readTeam = mock(async () => 25);
    const spend = createClaudeFallbackSpend({ readTeam, now: () => clock, ttlMs: 60_000 });
    expect(await spend.teamCents("t", "a")).toBe(25);
    spend.note("t", "a", 50);
    expect(await spend.teamCents("t", "a")).toBe(75);
    clock = 59_999;
    expect(await spend.teamCents("t", "a")).toBe(75);
    expect(readTeam).toHaveBeenCalledTimes(1);
    clock = 60_000;
    expect(await spend.teamCents("t", "a")).toBe(75);
    readTeam.mockImplementation(async () => 200);
    clock = 120_000;
    expect(await spend.teamCents("t", "a")).toBe(200);
    expect(readTeam).toHaveBeenCalledTimes(3);
  });

  test("the daily sum starts over at the UTC day boundary", async () => {
    let clock = Date.parse("2026-11-23T23:59:30Z");
    const readToday = mock(async () => (clock < Date.parse("2026-11-24T00:00:00Z") ? 9_000 : 0));
    const spend = createClaudeFallbackSpend({ readToday, now: () => clock });
    expect(await spend.todayCents("a")).toBe(9_000);
    spend.note("t", "a", 500);
    expect(await spend.todayCents("a")).toBe(9_500);
    clock = Date.parse("2026-11-24T00:00:10Z");
    expect(await spend.todayCents("a")).toBe(0);
  });

  test("concurrent requests share one read, and a failed read is not cached", async () => {
    let calls = 0;
    const spend = createClaudeFallbackSpend({
      readTeam: async () => {
        calls += 1;
        return calls === 1 ? null : 10;
      },
    });
    expect(await spend.teamCents("t", "a")).toBeNull();
    expect(await Promise.all([spend.teamCents("t", "a"), spend.teamCents("t", "a")])).toEqual([10, 10]);
    expect(calls).toBe(2);
  });

  test("the ledger reads are bounded sums in cents, and unpriced tokens are charged", async () => {
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
    const expected = (0.5 + 40_000 * UNPRICED_USD_PER_TOKEN) * 100;
    expect(await spend.teamCents("team-x", "acct-y")).toBeCloseTo(expected, 9);
    expect(bodies[0]).toContain("FROM coderouter.usage_events");
    expect(bodies[0]).toContain("team_id = {team_id:String}");
    expect(bodies[0]).toContain("upstream_account_id = {account_id:String}");
    expect(urls[0]).toContain("param_team_id=team-x");
    expect(urls[0]).toContain("param_account_id=acct-y");
    expect(await spend.todayCents("acct-y")).toBeCloseTo(expected, 9);
    expect(bodies[1]).toContain("event_time >= toStartOfDay(now('UTC'))");
    expect(bodies[1]).not.toContain("team_id");
  });
});

describe("house route through the proxy", () => {
  const houseUpstream: ClaudeUpstream = {
    accountId: "00000000-0000-4000-8000-0000000000aa",
    teamId: PLATFORM,
    kind: "anthropic_api_key",
    label: "",
    secret: { kind: "anthropic_api_key", apiKey: API_KEY },
    config: {},
    updatedAt: T0,
    fallback: true,
  };
  function proxy(selection: Awaited<ReturnType<ClaudeProxyDependencies["select"]>>, fetched: string[], models: (string | null)[] = []) {
    return createClaudeMessagesProxy({
      authenticate: async () => ({ ok: true, identity: { teamId: NEWCOMER, stackUserId: "user-1", vmId: "vm-1", token: "crt_x" } }),
      select: async (_teamId, input) => {
        models.push(input.model ? input.model() : "(none)");
        return selection;
      },
      cooldown: async () => {},
      touchUsed: async () => {},
      fetch: (async (input: string | URL | Request) => {
        fetched.push(String(input));
        return Response.json({ id: "msg_1", type: "message", model: "claude-sonnet-5", usage: { input_tokens: 1, output_tokens: 1 } });
      }) as typeof fetch,
      now: () => T0,
      capture: () => {},
      fallbackSpend: { ...createClaudeFallbackSpend(), teamCents: async () => 0, todayCents: async () => 0, note: () => {} },
    }, { now: () => 0, sleep: async () => {}, random: () => 0 });
  }
  const request = (model = "claude-sonnet-5") => new Request("https://coderouter.dev/v1/messages", {
    method: "POST",
    headers: { "content-type": "application/json", authorization: "Bearer crt_x" },
    body: JSON.stringify({ model, max_tokens: 8, messages: [{ role: "user", content: "hi" }] }),
  });

  test("at the cap: HTTP 402 with a typed reason and the pricing lane's copy, nothing forwarded", async () => {
    const fetched: string[] = [];
    const response = await proxy({ kind: "fallback_refused", reason: "included_usage_used_up" }, fetched)(request());
    expect(response.status).toBe(402);
    expect(response.headers.get("x-cmux-refusal-reason")).toBe("included_usage_used_up");
    expect(response.headers.get("retry-after")).toBeNull();
    expect(await response.json()).toEqual({
      type: "error",
      error: {
        type: "billing_error",
        reason: "included_usage_used_up",
        message: "You have used the model usage included with your pass. Sign in to Claude or Codex to keep going.",
      },
    });
    expect(fetched).toEqual([]);
    for (const message of Object.values(FALLBACK_REFUSAL_MESSAGES)) {
      expect(message).not.toMatch(/coderouter|anthropic|bedrock|aws|fallback|upstream|house/i);
    }
    expect(classifyCoderouterFault({ outcome: "no_usable_account", failureStage: "usage_cap", status: 402 } as never)).toBe("tenant");
  });

  test("a tier above Sonnet: 402 model_not_included, and the proxy hands select the request's model", async () => {
    const fetched: string[] = [];
    const models: (string | null)[] = [];
    const response = await proxy({ kind: "fallback_refused", reason: "model_not_included" }, fetched, models)(request("claude-opus-4-8"));
    expect(response.status).toBe(402);
    expect((await response.json()).error.reason).toBe("model_not_included");
    expect(models).toEqual(["claude-opus-4-8"]);
    expect(fetched).toEqual([]);
  });

  test("a usage read that fails: a retryable 503, nothing forwarded", async () => {
    const fetched: string[] = [];
    const response = await proxy({ kind: "fallback_unavailable" }, fetched)(request());
    expect(response.status).toBe(503);
    expect(response.headers.get("retry-after")).toBe("5");
    expect(fetched).toEqual([]);
  });

  test("under the cap: forwarded; at 80% each answer carries the one-line notice", async () => {
    for (const [spentCents, notice] of [[100, null], [400, INCLUDED_USAGE_NOTICE]] as const) {
      const fetched: string[] = [];
      const response = await proxy({ kind: "selected", upstream: houseUpstream, total: 1, healthy: 1, included: { spentCents, capCents: 500 } }, fetched)(request());
      expect(response.status).toBe(200);
      expect(response.headers.get("x-cmux-included-usage-notice")).toBe(notice);
      expect(fetched).toEqual(["https://api.anthropic.com/v1/messages"]);
    }
  });
});

describe("house route charges what it delivered", () => {
  const sse = (events: readonly unknown[]) =>
    events.map((event) => `event: ${(event as { type: string }).type}\ndata: ${JSON.stringify(event)}\n\n`).join("");
  const start = { type: "message_start", message: { id: "msg_1", type: "message", model: "claude-sonnet-5", usage: { input_tokens: 1000, cache_read_input_tokens: 5000, output_tokens: 1 } } };
  const delta = (text: string) => ({ type: "content_block_delta", index: 0, delta: { type: "text_delta", text } });
  const finalEvents = [{ type: "message_delta", delta: { stop_reason: "end_turn" }, usage: { output_tokens: 7 } }, { type: "message_stop" }];
  const houseUpstream = (fallback: boolean): ClaudeUpstream => ({
    accountId: "00000000-0000-4000-8000-0000000000aa",
    teamId: PLATFORM,
    kind: "anthropic_api_key",
    label: "",
    secret: { kind: "anthropic_api_key", apiKey: API_KEY },
    config: {},
    updatedAt: T0,
    ...(fallback ? { fallback: true as const } : {}),
  });

  /** Upstream sends `head` and then holds the stream open (or breaks it, or ends it with `tail`). */
  function proxy(options: { fallback: boolean; head: string; end: "hold" | "break" | string; status?: number }) {
    const notes: number[] = [];
    let upstreamCancelled = false;
    const handler = createClaudeMessagesProxy({
      authenticate: async () => ({ ok: true, identity: { teamId: NEWCOMER, stackUserId: "user-1", vmId: "vm-1", token: "crt_x" } }),
      select: async () => ({ kind: "selected", upstream: houseUpstream(options.fallback), total: 1, healthy: 1, ...(options.fallback ? { included: { spentCents: 0, capCents: 50 } } : {}) }),
      cooldown: async () => {},
      touchUsed: async () => {},
      fetch: (async () => {
        const encoder = new TextEncoder();
        let pulls = 0;
        const body = new ReadableStream<Uint8Array>({
          async pull(controller) {
            pulls += 1;
            if (pulls === 1) {
              controller.enqueue(encoder.encode(options.head));
              return;
            }
            if (options.end === "hold") return new Promise<void>(() => {});
            if (options.end === "break") {
              controller.error(new Error("upstream reset"));
              return;
            }
            controller.enqueue(encoder.encode(options.end));
            controller.close();
          },
          cancel() {
            upstreamCancelled = true;
          },
        });
        return new Response(body, { status: options.status ?? 200, headers: { "content-type": "text/event-stream" } });
      }) as typeof fetch,
      now: () => T0,
      capture: () => {},
      fallbackSpend: { ...createClaudeFallbackSpend(), teamCents: async () => 0, todayCents: async () => 0, note: (_team, _account, cents) => notes.push(cents) },
    }, { now: () => 0, sleep: async () => {}, random: () => 0 });
    const request = new Request("https://coderouter.dev/v1/messages", {
      method: "POST",
      headers: { "content-type": "application/json", authorization: "Bearer crt_x" },
      body: JSON.stringify({ model: "claude-sonnet-5", stream: true, max_tokens: 8, messages: [{ role: "user", content: "hi" }] }),
    });
    return { notes, run: () => handler(request), upstreamCancelled: () => upstreamCancelled };
  }

  async function readSome(response: Response, needle: string): Promise<void> {
    const reader = response.body!.getReader();
    const decoder = new TextDecoder();
    let text = "";
    while (!text.includes(needle)) {
      const next = await reader.read();
      if (next.done) break;
      text += decoder.decode(next.value, { stream: true });
    }
    await reader.cancel();
  }

  test("a stream the client cancels before its final usage is still charged", async () => {
    const text = "x".repeat(3000);
    const ctx = proxy({ fallback: true, head: sse([start, { type: "content_block_start", index: 0, content_block: { type: "text", text: "" } }, delta(text)]), end: "hold" });
    const response = await ctx.run();
    expect(response.status).toBe(200);
    await readSome(response, text);
    expect(ctx.upstreamCancelled()).toBe(true);
    expect(ctx.notes).toHaveLength(1);
    // 1000 input + 5000 cache reads + 1000 estimated output tokens at Sonnet list price: well above zero.
    expect(ctx.notes[0]).toBeGreaterThan(1);
  });

  test("a stream that breaks mid-answer is charged too", async () => {
    const ctx = proxy({ fallback: true, head: sse([start, delta("y".repeat(300))]), end: "break" });
    const response = await ctx.run();
    await response.text().catch(() => undefined);
    expect(ctx.notes).toHaveLength(1);
    expect(ctx.notes[0]).toBeGreaterThan(0);
  });

  test("a complete stream is charged its reported usage once", async () => {
    const ctx = proxy({ fallback: true, head: sse([start, delta("hello")]), end: sse(finalEvents) });
    await (await ctx.run()).text();
    expect(ctx.notes).toHaveLength(1);
    const plain = proxy({ fallback: true, head: sse([start, delta("hello")]), end: sse(finalEvents) });
    await (await plain.run()).text();
    expect(plain.notes).toEqual(ctx.notes);
  });

  test("an account of the team's own keeps today's observer: a cancelled stream records nothing", async () => {
    const ctx = proxy({ fallback: false, head: sse([start, delta("z".repeat(3000))]), end: "hold" });
    await readSome(await ctx.run(), "zzz");
    expect(ctx.notes).toEqual([]);
  });

  test("the estimate: message_start input, output from delta text or the reported count, nothing for nothing", () => {
    const encoder = new TextEncoder();
    const empty = new DeliveredClaudeUsage(400, "claude-sonnet-5");
    expect(empty.usage()).toBeNull();

    const streamed = new DeliveredClaudeUsage(400, "claude-sonnet-5");
    const bytes = encoder.encode(sse([start, delta("a".repeat(30)), delta("b".repeat(30))]));
    // Split mid-event: the parser must carry the partial event.
    streamed.push(bytes.slice(0, 50));
    streamed.push(bytes.slice(50));
    expect(streamed.usage()).toEqual({
      model: "claude-sonnet-5",
      inputTokens: 1000,
      cacheReadInputTokens: 5000,
      cacheCreationInputTokens: 0,
      outputTokens: 20,
      totalTokens: 6020,
    });
    streamed.push(encoder.encode(sse([{ type: "message_delta", delta: {}, usage: { output_tokens: 90 } }])));
    expect(streamed.usage()?.outputTokens).toBe(90);

    const json = new DeliveredClaudeUsage(400, "claude-sonnet-5");
    json.push(encoder.encode('{"id":"msg_1","content":[{"type":"text","text":"' + "c".repeat(100)));
    expect(json.usage()).toMatchObject({ inputTokens: 100, outputTokens: Math.ceil(149 / 3) });
  });
});

describe("agent access with the house route", () => {
  test("reports Claude available exactly when the house route applies and the team is under the cap", async () => {
    for (const [spent, expected] of [[0, true], [500, false]] as const) {
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

describe("house route holds each request's upper bound until it settles", () => {
  const reserve = (cents: number) => ({ ...pick(), reserveCents: () => cents });
  type Selected = Extract<Awaited<ReturnType<ReturnType<typeof setup>["service"]["select"]>>, { kind: "selected" }>;

  test("N concurrent requests at a cap that fits only k admit exactly k", async () => {
    // 50 cents left of the intro cap; each request is held at 12: four fit.
    const ctx = await withFallbackAccount({ plan: "next_intro", spent: 450 });
    const selections = await Promise.all(Array.from({ length: 10 }, () => ctx.service.select(NEWCOMER, reserve(12))));
    const admitted = selections.filter((selection): selection is Selected => selection.kind === "selected");
    expect(admitted).toHaveLength(4);
    expect(selections.filter((selection) => selection.kind !== "selected"))
      .toEqual(Array.from({ length: 6 }, () => ({ kind: "fallback_refused", reason: "included_usage_used_up" })));
    expect(ctx.spend.inFlightCents(NEWCOMER, ctx.fallbackId).team).toBe(48);
    for (const selection of admitted) {
      selection.reservation!.release();
      selection.reservation!.release();
    }
    expect(ctx.spend.inFlightCents(NEWCOMER, ctx.fallbackId)).toEqual({ team: 0, today: 0 });
    // Released: the room is back.
    expect((await ctx.service.select(NEWCOMER, reserve(12))).kind).toBe("selected");
  });

  test("the taste plans' shared daily budget holds in-flight requests the same way", async () => {
    const ctx = await withFallbackAccount({ plan: "next_taste", spent: 0, today: GLOBAL_DAILY_BUDGET_CENTS - 10 });
    const selections = await Promise.all(Array.from({ length: 5 }, () => ctx.service.select(NEWCOMER, reserve(4))));
    expect(selections.filter((selection) => selection.kind === "selected")).toHaveLength(2);
    expect(selections.filter((selection) => selection.kind !== "selected"))
      .toEqual(Array.from({ length: 3 }, () => ({ kind: "fallback_refused", reason: "included_daily_budget_reached" })));
    expect(ctx.spend.inFlightCents(NEWCOMER, ctx.fallbackId)).toEqual({ team: 8, today: 8 });
    for (const selection of selections) if (selection.kind === "selected") selection.reservation!.release();
    expect(ctx.spend.inFlightCents(NEWCOMER, ctx.fallbackId)).toEqual({ team: 0, today: 0 });
  });

  test("a request whose own bound exceeds what is left is refused, typed, though the team is under the cap", async () => {
    const ctx = await withFallbackAccount({ plan: "next_intro", spent: 480 });
    expect(await ctx.service.select(NEWCOMER, reserve(21))).toEqual({ kind: "fallback_refused", reason: "included_usage_used_up" });
    expect((await ctx.service.select(NEWCOMER, reserve(20))).kind).toBe("selected");
  });

  test("a bound that cannot be computed refuses (fail closed); an exhausted or aborted selection holds nothing", async () => {
    const ctx = await withFallbackAccount();
    for (const cents of [Number.NaN, 0, -1]) {
      expect(await ctx.service.select(NEWCOMER, reserve(cents))).toEqual({ kind: "fallback_unavailable" });
    }
    expect(await ctx.service.select(NEWCOMER, { ...pick(), reserveCents: () => { throw new Error("boom"); } }))
      .toEqual({ kind: "fallback_unavailable" });
    expect((await ctx.service.select(NEWCOMER, { ...reserve(5), excludedAccountIds: [ctx.fallbackId] })).kind).toBe("exhausted");
    const aborted = new AbortController();
    ctx.loadAccount.mockImplementation(async (id: string) => {
      aborted.abort();
      return ctx.store.rows.get(id) ?? null;
    });
    await expect(ctx.service.select(NEWCOMER, { ...reserve(5), signal: aborted.signal })).rejects.toThrow();
    ctx.loadAccount.mockImplementation(async (id: string) => ctx.store.rows.get(id) ?? null);
    expect(ctx.spend.inFlightCents(NEWCOMER, ctx.fallbackId)).toEqual({ team: 0, today: 0 });
  });

  test("env unset: nothing is held, and the bound is never computed", async () => {
    const ctx = await withFallbackAccount();
    ctx.setConfig({ kind: "off" });
    const reserveCents = mock(() => 5);
    expect(await ctx.service.select(NEWCOMER, { ...pick(), reserveCents })).toEqual({ kind: "none" });
    expect(reserveCents).not.toHaveBeenCalled();
    // A team with its own account never computes it either.
    ctx.setConfig(ctx.on);
    await ctx.plain.add(NEWCOMER, "user-1", { kind: "anthropic_api_key", apiKey: API_KEY_2 }, "team");
    const own = await ctx.service.select(NEWCOMER, { ...pick(), reserveCents });
    expect(own.kind).toBe("selected");
    expect((own as Selected).reservation).toBeUndefined();
    expect(reserveCents).not.toHaveBeenCalled();
  });

  test("the bound: bytes as uncached input plus max_tokens of output at list price; unknown models at the top rate", () => {
    const small = fallbackReservationCents({ model: "claude-sonnet-4-5", bytes: 4_000, maxTokens: 1_000 });
    const larger = fallbackReservationCents({ model: "claude-sonnet-4-5", bytes: 4_000, maxTokens: 2_000 });
    expect(small).toBeGreaterThan(0);
    expect(larger).toBeGreaterThan(small);
    // No max_tokens: held for the largest output.
    expect(fallbackReservationCents({ model: "claude-sonnet-4-5", bytes: 4_000, maxTokens: null }))
      .toBe(fallbackReservationCents({ model: "claude-sonnet-4-5", bytes: 4_000, maxTokens: 64_000 }));
    expect(fallbackReservationCents({ model: "not-a-model", bytes: 4_000, maxTokens: 1_000 }))
      .toBeCloseTo(2_000 * UNPRICED_USD_PER_TOKEN * 100, 9);
  });

  describe("through the proxy, the hold is released however the request ends", () => {
    const sse = (events: readonly unknown[]) =>
      events.map((event) => `event: ${(event as { type: string }).type}\ndata: ${JSON.stringify(event)}\n\n`).join("");
    const start = { type: "message_start", message: { id: "msg_1", type: "message", model: "claude-sonnet-4-5", usage: { input_tokens: 100, output_tokens: 1 } } };
    const delta = (text: string) => ({ type: "content_block_delta", index: 0, delta: { type: "text_delta", text } });
    const finalEvents = [{ type: "message_delta", delta: { stop_reason: "end_turn" }, usage: { output_tokens: 7 } }, { type: "message_stop" }];

    async function houseProxy(options: { head?: string; end?: "hold" | "break" | string; status?: number; throws?: boolean; maxTokens?: number; spent?: number; plan?: string }) {
      const ctx = await withFallbackAccount({ plan: options.plan ?? "next_intro", spent: options.spent ?? 0 });
      const notes: number[] = [];
      const fetched: string[] = [];
      let inFlightAtFetch = -1;
      let clock = 0;
      const handler = createClaudeMessagesProxy({
        authenticate: async () => ({ ok: true, identity: { teamId: NEWCOMER, stackUserId: "user-1", vmId: "vm-1", token: "crt_x" } }),
        select: (teamId, input) => ctx.service.select(teamId, { ...input, access: vmAccess }),
        cooldown: async () => {},
        touchUsed: async () => {},
        fetch: (async (input: string | URL | Request) => {
          fetched.push(String(input));
          inFlightAtFetch = ctx.spend.inFlightCents(NEWCOMER, ctx.fallbackId).team;
          if (options.throws) throw new Error("connect reset");
          const encoder = new TextEncoder();
          let pulls = 0;
          const body = new ReadableStream<Uint8Array>({
            async pull(controller) {
              pulls += 1;
              if (pulls === 1) {
                controller.enqueue(encoder.encode(options.head ?? ""));
                return;
              }
              if (options.end === "hold") return new Promise<void>(() => {});
              if (options.end === "break") {
                controller.error(new Error("upstream reset"));
                return;
              }
              controller.enqueue(encoder.encode(options.end ?? ""));
              controller.close();
            },
          });
          return new Response(body, { status: options.status ?? 200, headers: { "content-type": options.status ? "application/json" : "text/event-stream" } });
        }) as typeof fetch,
        now: () => T0,
        capture: () => {},
        fallbackSpend: { ...ctx.spend, note: (_team, _account, cents) => notes.push(cents) },
      }, {
        // The clock moves only by the proxy's own waits, so a failing upstream runs out its deadline.
        now: () => clock,
        sleep: async (ms: number) => {
          clock += Math.max(ms, 1);
        },
        random: () => 0,
      });
      const request = new Request("https://coderouter.dev/v1/messages", {
        method: "POST",
        headers: { "content-type": "application/json", authorization: "Bearer crt_x" },
        body: JSON.stringify({ model: "claude-sonnet-4-5", stream: true, max_tokens: options.maxTokens ?? 1_000, messages: [{ role: "user", content: "hi" }] }),
      });
      const inFlight = () => ctx.spend.inFlightCents(NEWCOMER, ctx.fallbackId).team;
      return { run: () => handler(request), notes, fetched, inFlight, inFlightAtFetch: () => inFlightAtFetch };
    }

    test("success: held while the answer streams, then swapped for its charge", async () => {
      const ctx = await houseProxy({ head: sse([start, delta("hello")]), end: sse(finalEvents) });
      const response = await ctx.run();
      expect(ctx.inFlightAtFetch()).toBeGreaterThan(0);
      expect(ctx.inFlight()).toBe(ctx.inFlightAtFetch());
      await response.text();
      expect(ctx.notes).toHaveLength(1);
      expect(ctx.inFlight()).toBe(0);
    });

    test("an upstream error answer releases at once", async () => {
      const ctx = await houseProxy({ head: JSON.stringify({ type: "error", error: { type: "invalid_request_error", message: "bad" } }), end: "", status: 400 });
      const response = await ctx.run();
      expect(response.status).toBe(400);
      expect(ctx.inFlight()).toBe(0);
      await response.text();
      expect(ctx.notes).toEqual([]);
      expect(ctx.inFlight()).toBe(0);
    });

    test("a transport failure releases before the next selection", async () => {
      const ctx = await houseProxy({ throws: true });
      const response = await ctx.run();
      expect(response.status).toBeGreaterThanOrEqual(500);
      expect(ctx.fetched.length).toBeGreaterThan(0);
      expect(ctx.inFlight()).toBe(0);
    });

    test("a client cancel settles the charge and releases", async () => {
      const ctx = await houseProxy({ head: sse([start, delta("x".repeat(300))]), end: "hold" });
      const response = await ctx.run();
      const reader = response.body!.getReader();
      await reader.read();
      expect(ctx.inFlight()).toBeGreaterThan(0);
      await reader.cancel();
      expect(ctx.notes).toHaveLength(1);
      expect(ctx.inFlight()).toBe(0);
    });

    test("a stream that breaks settles the charge and releases", async () => {
      const ctx = await houseProxy({ head: sse([start, delta("y".repeat(300))]), end: "break" });
      await (await ctx.run()).text().catch(() => undefined);
      expect(ctx.notes).toHaveLength(1);
      expect(ctx.inFlight()).toBe(0);
    });

    test("a request whose own bound exceeds what is left: 402 with the typed reason, nothing forwarded", async () => {
      // 20 cents left; 2,000 output tokens at Sonnet's list price alone is 3 cents, 20,000 is 30.
      const ctx = await houseProxy({ spent: 480, maxTokens: 20_000, head: sse([start]), end: sse(finalEvents) });
      const response = await ctx.run();
      expect(response.status).toBe(402);
      expect(response.headers.get("x-cmux-refusal-reason")).toBe("included_usage_used_up");
      expect((await response.json()).error.reason).toBe("included_usage_used_up");
      expect(ctx.fetched).toEqual([]);
      expect(ctx.inFlight()).toBe(0);
      const fits = await houseProxy({ spent: 480, maxTokens: 2_000, head: sse([start]), end: sse(finalEvents) });
      expect((await fits.run()).status).toBe(200);
    });
  });
});
