import { afterAll, beforeAll, beforeEach, describe, expect, mock, spyOn, test } from "bun:test";
import * as analytics from "../services/coderouter/analytics";
import { VM_PLACEHOLDER_API_KEY } from "../services/coderouter/routeTokenAuth";

type SelectInput = {
  teamId: string;
  provider: string;
  sessionKey: string | null;
  excludedAccountIds?: readonly string[];
  signal?: AbortSignal;
};

let selectInputs: SelectInput[] = [];
let accountsToServe: { id: string; sticky: boolean }[] = [];
let cooldowns: string[] = [];
let upstreamStatuses: number[] = [];
let credentialBusyBudgets = new Map<string, number>();
let credentialCalls: string[] = [];
let authenticatedTokens: string[] = [];
const BOUND_TOKEN = "crt_bound-to-vm-1";

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

const { createCodexModelsProxy, createCodexResponsesProxy } = await import("../services/coderouter/codexProxy");

const proxy = createCodexResponsesProxy({
  authenticate: async (token) => {
    authenticatedTokens.push(token);
    return {
      teamId: "team-1",
      stackUserId: "stack-user-1",
      vmId: token === BOUND_TOKEN ? "vm-1" : null,
    };
  },
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
  authenticatedTokens = [];
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

  test("bounds all upstream header waits to one request budget", async () => {
    const selected: string[] = [];
    let logicalNow = 0;
    const rateLimitedFetch = (async () => {
      // Advance a deterministic clock as each simulated header wait elapses.
      logicalNow += 120;
      return new Response("rate limited", {
        status: 429,
        headers: { "content-type": "application/json" },
      });
    }) as typeof fetch;
    const boundedProxy = createCodexResponsesProxy({
      authenticate: async () => ({
        teamId: "team-1",
        stackUserId: "stack-user-1",
        vmId: null,
      }),
      select: async () => {
        const id = `acct-${selected.length + 1}`;
        selected.push(id);
        return { id, vaultRevision: 1, credentialExpiresAt: null, sticky: false };
      },
      credential: async ({ accountId }) => ({
        provider: "codex" as const,
        accessToken: `access-${accountId}`,
        refreshToken: "refresh",
        idToken: "id",
        accountId: "chatgpt-account",
        email: "person@example.com",
        expiresAt: Date.now() + 60_000,
      }),
      cooldown: async () => {},
    }, {
      fetch: rateLimitedFetch,
      now: () => logicalNow,
      upstreamHeadersBudgetMs: 200,
      upstreamHeadersTimeoutMs: 120,
    });

    const response = await boundedProxy(responsesRequest());

    expect(response.status).toBe(429);
    expect(selected).toEqual(["acct-1", "acct-2"]);
  });

  test("bounds account selection to the request failover deadline and aborts it", async () => {
    let selectionSignal: AbortSignal | undefined;
    const boundedProxy = createCodexResponsesProxy({
      authenticate: async () => ({
        teamId: "team-1",
        stackUserId: "stack-user-1",
        vmId: null,
      }),
      select: async (input) => {
        selectionSignal = (input as SelectInput).signal;
        return await new Promise<null>(() => undefined);
      },
      credential: async () => {
        throw new Error("credential should not run");
      },
      cooldown: async () => {},
    }, {
      now: () => 0,
      upstreamHeadersBudgetMs: 30,
      upstreamHeadersTimeoutMs: 10,
    });

    const started = performance.now();
    const response = await boundedProxy(responsesRequest());

    expect(response.status).toBe(503);
    expect(selectionSignal).toBeDefined();
    expect(selectionSignal?.aborted).toBe(true);
    expect(performance.now() - started).toBeLessThan(1_000);
  });

  test("bounds credential loading to the request failover deadline and aborts it", async () => {
    let credentialSignal: AbortSignal | undefined;
    const boundedProxy = createCodexResponsesProxy({
      authenticate: async () => ({
        teamId: "team-1",
        stackUserId: "stack-user-1",
        vmId: null,
      }),
      select: async () => ({ id: "acct-1", vaultRevision: 1, credentialExpiresAt: null, sticky: false }),
      credential: async (input) => {
        credentialSignal = (input as typeof input & { signal?: AbortSignal }).signal;
        return await new Promise<never>(() => undefined);
      },
      cooldown: async () => {},
    }, {
      now: () => 0,
      upstreamHeadersBudgetMs: 30,
      upstreamHeadersTimeoutMs: 10,
    });

    const started = performance.now();
    const response = await boundedProxy(responsesRequest());

    expect(response.status).toBe(503);
    expect(credentialSignal).toBeDefined();
    expect(credentialSignal?.aborted).toBe(true);
    expect(performance.now() - started).toBeLessThan(1_000);
  });

  test("does not fail over after the caller cancels the request", async () => {
    const controller = new AbortController();
    const selected: string[] = [];
    const abortingFetch = (async () => {
      controller.abort();
      throw new DOMException("aborted", "AbortError");
    }) as typeof fetch;
    const abortingProxy = createCodexResponsesProxy({
      authenticate: async () => ({
        teamId: "team-1",
        stackUserId: "stack-user-1",
        vmId: null,
      }),
      select: async () => {
        const id = `acct-${selected.length + 1}`;
        selected.push(id);
        return { id, vaultRevision: 1, credentialExpiresAt: null, sticky: false };
      },
      credential: async ({ accountId }) => ({
        provider: "codex" as const,
        accessToken: `access-${accountId}`,
        refreshToken: "refresh",
        idToken: "id",
        accountId: "chatgpt-account",
        email: "person@example.com",
        expiresAt: Date.now() + 60_000,
      }),
      cooldown: async () => {},
    }, { fetch: abortingFetch });
    const request = new Request("https://coderouter.dev/v1/responses", {
      method: "POST",
      headers: {
        authorization: "Bearer crt_token",
        "content-type": "application/json",
      },
      body: JSON.stringify({ model: "gpt-test", input: [] }),
      signal: controller.signal,
    });

    await expect(abortingProxy(request)).rejects.toMatchObject({ name: "AbortError" });
    expect(selected).toEqual(["acct-1"]);
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

describe("codex models proxy outcomes", () => {
  test("reports provider unavailable when upstream headers time out", async () => {
    let selected = false;
    const modelsProxy = createCodexModelsProxy({
      authenticate: async () => ({ teamId: "team-1", stackUserId: "stack-user-1", vmId: null }),
      select: async () => {
        if (selected) return null;
        selected = true;
        return { id: "acct-1", vaultRevision: 1, credentialExpiresAt: null };
      },
      credential: async () => ({
        provider: "codex" as const,
        accessToken: "access",
        refreshToken: "refresh",
        idToken: "id",
        accountId: "chatgpt-account",
        email: "person@example.com",
        expiresAt: Date.now() + 60_000,
      }),
      cooldown: async () => {},
      providerRead: async () => {
        throw new Error("upstream headers timed out");
      },
    });
    const response = await modelsProxy(new Request("https://coderouter.dev/v1/models", {
      headers: { authorization: "Bearer crt_token", "anthropic-version": "2023-06-01" },
    }));
    expect(response.status).toBe(503);
    const body = await response.json() as { error: string };
    expect(body.error).toBe("provider_unavailable");
  });
});

describe("codex responses proxy VM-bound route tokens", () => {
  function edgeRequest(headers: Record<string, string>): Request {
    return new Request("https://coderouter.dev/v1/responses", {
      method: "POST",
      headers: {
        authorization: `Bearer ${VM_PLACEHOLDER_API_KEY}`,
        "content-type": "application/json",
        ...headers,
      },
      body: JSON.stringify({ model: "gpt-test", input: [] }),
    });
  }

  test("a bound token with the matching x-cmux-vm-id header is routed", async () => {
    accountsToServe = [{ id: "acct-1", sticky: false }];
    const response = await proxy(edgeRequest({
      "x-coderouter-route-token": BOUND_TOKEN,
      "x-cmux-vm-id": "vm-1",
    }));
    expect(response.status).toBe(200);
    expect(authenticatedTokens).toEqual([BOUND_TOKEN]);
    expect(selectInputs[0]?.teamId).toBe("team-1");
  });

  test("a bound token without x-cmux-vm-id is rejected as vm_mismatch", async () => {
    accountsToServe = [{ id: "acct-1", sticky: false }];
    const capture = spyOn(analytics, "captureCoderouterEvent");
    try {
      const response = await proxy(edgeRequest({
        "x-coderouter-route-token": BOUND_TOKEN,
      }));
      expect(response.status).toBe(401);
      const body = await response.json() as { error: string; message: string };
      expect(body.error).toBe("unauthorized");
      expect(body.message).toBe(
        "This machine's coderouter credential does not match the machine it was issued to.",
      );
      expect(selectInputs).toHaveLength(0);
      const rejection = capture.mock.calls
        .map((call) => call[0])
        .find((event) => event.event === "coderouter_auth_rejected");
      expect(rejection?.properties).toEqual({
        surface: "responses",
        reason: "vm_mismatch",
      });
    } finally {
      capture.mockRestore();
    }
  });

  test("a bound token with another machine's x-cmux-vm-id is rejected", async () => {
    accountsToServe = [{ id: "acct-1", sticky: false }];
    const response = await proxy(edgeRequest({
      "x-coderouter-route-token": BOUND_TOKEN,
      "x-cmux-vm-id": "vm-2",
    }));
    expect(response.status).toBe(401);
    expect(selectInputs).toHaveLength(0);
  });

  test("an unbound token ignores x-cmux-vm-id", async () => {
    accountsToServe = [{ id: "acct-1", sticky: false }];
    const response = await proxy(responsesRequest({ "x-cmux-vm-id": "vm-9" }));
    expect(response.status).toBe(200);
    expect(selectInputs).toHaveLength(1);
  });

  test("the placeholder API key alone is never a credential", async () => {
    accountsToServe = [{ id: "acct-1", sticky: false }];
    const response = await proxy(edgeRequest({ "x-cmux-vm-id": "vm-1" }));
    expect(response.status).toBe(401);
    expect(authenticatedTokens).toEqual([]);
    const body = await response.json() as { message: string };
    expect(body.message).toBe("Sign in with `cr login` and retry.");
  });
});
