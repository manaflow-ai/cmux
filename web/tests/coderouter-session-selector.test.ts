import { describe, expect, test } from "bun:test";

import { createSessionAccountSelector } from "../services/coderouter/repository";

type Call = { fn: string; args: unknown[] };

function makeDependencies(options: {
  bound?: { id: string; vaultRevision: number; credentialExpiresAt: Date | null } | null;
  placed?: { id: string; vaultRevision: number; credentialExpiresAt: Date | null } | null;
}) {
  const calls: Call[] = [];
  return {
    calls,
    dependencies: {
      sweepLeases: async (...args: unknown[]) => {
        calls.push({ fn: "sweepLeases", args });
      },
      findBound: async (...args: unknown[]) => {
        calls.push({ fn: "findBound", args });
        return options.bound ?? null;
      },
      claim: async (...args: unknown[]) => {
        calls.push({ fn: "claim", args });
        return options.placed ?? null;
      },
      bind: async (...args: unknown[]) => {
        calls.push({ fn: "bind", args });
      },
    },
  };
}

const account = (id: string) => ({
  id,
  vaultRevision: 3,
  credentialExpiresAt: null,
});

describe("coderouter session account selector", () => {
  test("honors an existing usable binding and does not place", async () => {
    const { calls, dependencies } = makeDependencies({ bound: account("acct-1") });
    const select = createSessionAccountSelector(dependencies);
    const result = await select({
      teamId: "team-1",
      provider: "codex",
      sessionKey: "session-a",
    });
    expect(result).toEqual({ ...account("acct-1"), sticky: true });
    expect(calls.map((c) => c.fn)).toEqual(["sweepLeases", "findBound"]);
  });

  test("places and binds a new session when no binding exists", async () => {
    const { calls, dependencies } = makeDependencies({
      bound: null,
      placed: account("acct-2"),
    });
    const select = createSessionAccountSelector(dependencies);
    const result = await select({
      teamId: "team-1",
      provider: "codex",
      sessionKey: "session-b",
    });
    expect(result).toEqual({ ...account("acct-2"), sticky: false });
    expect(calls.map((c) => c.fn)).toEqual([
      "sweepLeases",
      "findBound",
      "claim",
      "bind",
    ]);
    expect(calls[3]?.args).toEqual(["team-1", "codex", "session-b", "acct-2"]);
  });

  test("rebinds when the bound account is no longer usable", async () => {
    const { calls, dependencies } = makeDependencies({
      bound: null,
      placed: account("acct-3"),
    });
    const select = createSessionAccountSelector(dependencies);
    const result = await select({
      teamId: "team-1",
      provider: "codex",
      sessionKey: "session-c",
      excludedAccountIds: ["acct-1"],
    });
    expect(result?.sticky).toBe(false);
    expect(result?.id).toBe("acct-3");
    const findBound = calls.find((c) => c.fn === "findBound");
    expect(findBound?.args).toEqual(["team-1", "codex", "session-c", ["acct-1"]]);
    const claim = calls.find((c) => c.fn === "claim");
    expect(claim?.args).toEqual(["team-1", "codex", ["acct-1"]]);
  });

  test("skips stickiness entirely without a session key", async () => {
    const { calls, dependencies } = makeDependencies({ placed: account("acct-4") });
    const select = createSessionAccountSelector(dependencies);
    const result = await select({
      teamId: "team-1",
      provider: "codex",
      sessionKey: null,
    });
    expect(result).toEqual({ ...account("acct-4"), sticky: false });
    expect(calls.map((c) => c.fn)).toEqual(["sweepLeases", "claim"]);
  });

  test("returns null when no account is usable", async () => {
    const { calls, dependencies } = makeDependencies({ bound: null, placed: null });
    const select = createSessionAccountSelector(dependencies);
    const result = await select({
      teamId: "team-1",
      provider: "codex",
      sessionKey: "session-d",
    });
    expect(result).toBeNull();
    expect(calls.some((c) => c.fn === "bind")).toBe(false);
  });
});
