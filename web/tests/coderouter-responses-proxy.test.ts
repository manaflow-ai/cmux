import { afterAll, beforeAll, beforeEach, describe, expect, mock, test } from "bun:test";

type SelectInput = {
  teamId: string;
  provider: string;
  sessionKey: string | null;
  excludedAccountIds?: readonly string[];
};

let selectInputs: SelectInput[] = [];
let accountsToServe: { id: string; sticky: boolean }[] = [];
let cooldowns: string[] = [];
let upstreamStatuses: number[] = [];
let credentialBusyBudgets = new Map<string, number>();
let credentialCalls: string[] = [];

const originalFetch = globalThis.fetch;
beforeAll(() => {
  globalThis.fetch = mock(async () => {
    const status = upstreamStatuses.shift() ?? 200;
    return new Response("data: done\n\n", {
      status,
      headers: { "content-type": "text/event-stream" },
    });
  }) as typeof fetch;
});
afterAll(() => {
  globalThis.fetch = originalFetch;
});

const { createCodexResponsesProxy } = await import("../services/coderouter/codexProxy");

const proxy = createCodexResponsesProxy({
  authenticate: async () => ({ teamId: "team-1", stackUserId: "stack-user-1" }),
  select: async (input) => {
    selectInputs.push({
      ...(input as SelectInput),
      excludedAccountIds: [...(input.excludedAccountIds ?? [])],
    });
    const next = accountsToServe.shift();
    return next
      ? {
        id: next.id,
        vaultRevision: 1,
        credentialExpiresAt: null,
        sticky: next.sticky,
      }
      : null;
  },
  credential: async ({ accountId }) => {
    if (credentialBusyBudgets.get(accountId)) {
      credentialBusyBudgets.set(
        accountId,
        (credentialBusyBudgets.get(accountId) ?? 1) - 1,
      );
      throw Object.assign(new Error("busy"), { _tag: "CodeRouterRefreshBusy" });
    }
    credentialCalls.push(accountId);
    return {
      provider: "codex",
      accessToken: `access-${accountId}`,
      refreshToken: "refresh",
      idToken: "id",
      accountId: "chatgpt-account",
      email: "person@example.com",
      expiresAt: Date.now() + 60_000,
    };
  },
  cooldown: async (accountId) => {
    cooldowns.push(accountId);
  },
});

beforeEach(() => {
  selectInputs = [];
  accountsToServe = [];
  cooldowns = [];
  upstreamStatuses = [];
  credentialBusyBudgets = new Map();
  credentialCalls = [];
});

function responsesRequest(headers: Record<string, string> = {}): Request {
  return new Request("https://coderouter.dev/v1/responses", {
    method: "POST",
    headers: {
      authorization: "Bearer crt_token",
      "content-type": "application/json",
      ...headers,
    },
    body: JSON.stringify({ model: "gpt-test", input: [] }),
  });
}

describe("codex responses proxy session routing", () => {
  test("passes the session_id header to account selection", async () => {
    accountsToServe = [{ id: "acct-1", sticky: true }];
    const response = await proxy(responsesRequest({ session_id: "session-abc" }));
    expect(response.status).toBe(200);
    expect(selectInputs).toHaveLength(1);
    expect(selectInputs[0]?.sessionKey).toBe("session-abc");
    expect(selectInputs[0]?.teamId).toBe("team-1");
    expect(selectInputs[0]?.provider).toBe("codex");
  });

  test("selects without a session key when the header is missing", async () => {
    accountsToServe = [{ id: "acct-1", sticky: false }];
    const response = await proxy(responsesRequest());
    expect(response.status).toBe(200);
    expect(selectInputs[0]?.sessionKey).toBeNull();
  });

  test("ignores oversized session ids", async () => {
    accountsToServe = [{ id: "acct-1", sticky: false }];
    await proxy(responsesRequest({ session_id: "x".repeat(600) }));
    expect(selectInputs[0]?.sessionKey).toBeNull();
  });

  test("cools down a rate-limited account and retries excluding it", async () => {
    accountsToServe = [
      { id: "acct-1", sticky: true },
      { id: "acct-2", sticky: false },
    ];
    upstreamStatuses = [429, 200];
    const response = await proxy(responsesRequest({ session_id: "session-move" }));
    expect(response.status).toBe(200);
    expect(cooldowns).toEqual(["acct-1"]);
    expect(selectInputs).toHaveLength(2);
    expect(selectInputs[1]?.excludedAccountIds).toEqual(["acct-1"]);
    expect(selectInputs[1]?.sessionKey).toBe("session-move");
  });

  test("a sticky session waits out an in-flight refresh instead of moving", async () => {
    accountsToServe = [{ id: "acct-1", sticky: true }];
    credentialBusyBudgets.set("acct-1", 2);
    const response = await proxy(responsesRequest({ session_id: "session-wait" }));
    expect(response.status).toBe(200);
    expect(selectInputs).toHaveLength(1);
    expect(credentialCalls).toEqual(["acct-1"]);
  });

  test("a non-sticky request moves immediately on refresh-busy", async () => {
    accountsToServe = [
      { id: "acct-1", sticky: false },
      { id: "acct-2", sticky: false },
    ];
    credentialBusyBudgets.set("acct-1", 1);
    const response = await proxy(responsesRequest());
    expect(response.status).toBe(200);
    expect(credentialCalls).toEqual(["acct-2"]);
    expect(selectInputs).toHaveLength(2);
  });

  test("returns no_usable_account when selection is exhausted", async () => {
    accountsToServe = [];
    const response = await proxy(responsesRequest({ session_id: "session-dry" }));
    expect(response.status).toBe(503);
    const body = await response.json() as { error: string };
    expect(body.error).toBe("no_usable_account");
  });
});
