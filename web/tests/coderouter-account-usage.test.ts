import { describe, expect, mock, test } from "bun:test";

import {
  USAGE_FRESH_MS,
  USAGE_MAX_STALE_MS,
  createAccountsWithUsage,
  type UsageDependencies,
} from "../services/coderouter/usage";

const NOW = Date.parse("2026-09-23T12:00:00.000Z");

function account(id: string, overrides: Record<string, unknown> = {}) {
  return { id, provider: "codex", state: "active", label: `${id}@example.com`, ...overrides };
}

function reading(ageMs: number, usage: unknown = { plan_type: "pro" }, usageError: string | null = null) {
  return { usage, usageError, fetchedAt: new Date(NOW - ageMs) };
}

function harness(options: {
  readonly accounts: readonly Record<string, unknown>[];
  readonly stored?: ReadonlyMap<string, ReturnType<typeof reading>>;
  readonly claimed?: (ids: readonly string[]) => readonly string[];
}) {
  const deferred: Promise<unknown>[] = [];
  const read = mock(async (_teamId: string, accountId: string) => ({ usage: { live: accountId } }));
  const store = mock(async () => undefined);
  const claimRefresh = mock(async (_teamId: string, ids: readonly string[]) => options.claimed?.(ids) ?? ids);
  const dependencies: UsageDependencies = {
    listAccounts: (async () => options.accounts) as never,
    storedUsage: async () => options.stored ?? new Map(),
    claimRefresh: claimRefresh as never,
    credentials: async () => [],
    read: read as never,
    store: store as never,
    defer: (task) => { deferred.push(task); },
    now: () => NOW,
  };
  const { accountsWithUsage } = createAccountsWithUsage(dependencies);
  return { accountsWithUsage, read, store, claimRefresh, deferred };
}

describe("coderouter status usage", () => {
  test("serves fresh readings without a provider read", async () => {
    const { accountsWithUsage, read, deferred } = harness({
      accounts: [account("a")],
      stored: new Map([["a", reading(5_000)]]),
    });
    const result = await accountsWithUsage("team-1");
    expect(read).not.toHaveBeenCalled();
    expect(deferred).toHaveLength(0);
    expect(result.accounts[0]).toMatchObject({ id: "a", usage: { plan_type: "pro" } });
    expect(result.usageGeneratedAtMs).toBe(NOW - 5_000);
    expect(result.cacheMaxAgeSeconds).toBe(USAGE_FRESH_MS / 1_000);
  });

  test("serves a stale reading at once and refreshes the claimed ones after the response", async () => {
    const { accountsWithUsage, read, store, claimRefresh, deferred } = harness({
      accounts: [account("a"), account("b")],
      stored: new Map([["a", reading(USAGE_FRESH_MS + 1)], ["b", reading(USAGE_FRESH_MS + 1)]]),
      claimed: () => ["a"],
    });
    const result = await accountsWithUsage("team-1");
    expect(result.accounts.map((row) => (row as { usage?: unknown }).usage)).toEqual([
      { plan_type: "pro" },
      { plan_type: "pro" },
    ]);
    expect(deferred).toHaveLength(1);
    await Promise.all(deferred);
    expect(claimRefresh).toHaveBeenCalledWith("team-1", ["a", "b"], new Date(NOW), new Date(NOW - USAGE_FRESH_MS));
    // Another instance holds b's claim.
    expect(read.mock.calls.map((call) => call[1])).toEqual(["a"]);
    expect(store).toHaveBeenCalledWith("team-1", "a", { usage: { live: "a" } }, new Date(NOW));
  });

  test("reads missing and too-old readings before answering", async () => {
    const { accountsWithUsage, read, store, deferred } = harness({
      accounts: [account("missing"), account("old")],
      stored: new Map([["old", reading(USAGE_MAX_STALE_MS + 1)]]),
    });
    const result = await accountsWithUsage("team-1");
    expect(read.mock.calls.map((call) => call[1]).sort()).toEqual(["missing", "old"]);
    expect(store).toHaveBeenCalledTimes(2);
    expect(deferred).toHaveLength(0);
    expect(result.accounts).toEqual([
      expect.objectContaining({ id: "missing", usage: { live: "missing" } }),
      expect.objectContaining({ id: "old", usage: { live: "old" } }),
    ]);
    expect(result.usageGeneratedAtMs).toBe(NOW);
  });

  test("keeps a stored provider error and skips inactive and non-Codex accounts", async () => {
    const { accountsWithUsage, read } = harness({
      accounts: [account("failed"), account("broken", { state: "broken" }), account("go", { provider: "opencode-go" })],
      stored: new Map([["failed", reading(1_000, null, "HTTP 401")]]),
    });
    const result = await accountsWithUsage("team-1");
    expect(read).not.toHaveBeenCalled();
    expect(result.accounts[0]).toMatchObject({ id: "failed", usageError: "HTTP 401" });
    expect(result.accounts[0]).not.toHaveProperty("usage");
    expect(result.accounts[1]).not.toHaveProperty("usage");
    expect(result.accounts[2]).not.toHaveProperty("usage");
  });

  test("a failed store still returns the live reading", async () => {
    const h = harness({ accounts: [account("a")] });
    h.store.mockImplementation(async () => { throw new Error("db down"); });
    const result = await h.accountsWithUsage("team-1");
    expect(result.accounts[0]).toMatchObject({ usage: { live: "a" } });
  });
});
