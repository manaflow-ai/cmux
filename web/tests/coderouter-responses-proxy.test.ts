import { afterAll, beforeAll, beforeEach, describe, expect, mock, spyOn, test } from "bun:test";
import * as analytics from "../services/coderouter/analytics";
import { VM_PLACEHOLDER_API_KEY } from "../services/coderouter/routeTokenAuth";

type SelectInput = {
  teamId: string;
  provider: string | readonly string[];
  sessionKey: string | null;
  excludedAccountIds?: readonly string[];
  signal?: AbortSignal;
};

let selectInputs: SelectInput[] = [];
let accountsToServe: { id: string; sticky: boolean }[] = [];
let cooldowns: string[] = [];
let capacityCooldowns: { accountId: string; durationMs: number; failureCode?: string }[] = [];
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
        provider: "codex" as const,
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
  capacityCooldowns = [];
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
  function testCredential(accountId: string) {
    return {
      provider: "codex" as const,
      accessToken: `access-${accountId}`,
      refreshToken: "refresh",
      idToken: "id",
      accountId: "chatgpt-account",
      email: "person@example.com",
      expiresAt: Date.now() + 60_000,
    };
  }

  function capacityProxy(fetchImpl: typeof fetch) {
    const candidates = ["acct-capacity", "acct-healthy"];
    return createCodexResponsesProxy({
      authenticate: async () => ({ teamId: "team-1", stackUserId: "stack-user-1", vmId: null }),
      select: async (input) => {
        const excluded = new Set(input.excludedAccountIds ?? []);
        const id = candidates.find((candidate) => !excluded.has(candidate));
        if (!id) return null;
        return { id, provider: "codex" as const, vaultRevision: 1, credentialExpiresAt: null, sticky: false };
      },
      credential: async ({ accountId }) => testCredential(accountId),
      cooldown: async (accountId, durationMs, _signal, failureCode) => {
        cooldowns.push(accountId);
        capacityCooldowns.push({ accountId, durationMs, failureCode });
      },
    }, { fetch: fetchImpl });
  }

  test("fails over a pre-output usage_limit_reached SSE event", async () => {
    const bodies = [
      `data: ${JSON.stringify({ type: "response.created" })}\n\n` +
        `data: ${JSON.stringify({ type: "error", code: "usage_limit_reached" })}\n\n`,
      `data: ${JSON.stringify({ type: "response.output_text.delta", delta: "ok" })}\n\n`,
    ];
    const response = await capacityProxy((async () => new Response(bodies.shift()!, {
      status: 200,
      headers: { "content-type": "text/event-stream" },
    })) as typeof fetch)(responsesRequest());
    expect(response.status).toBe(200);
    expect(await response.text()).toContain('"delta":"ok"');
    expect(cooldowns).toEqual(["acct-capacity"]);
  });

  test("fails over the Codex server_overloaded error code", async () => {
    const bodies = [
      `data: ${JSON.stringify({
        type: "error",
        message: "Try again later.",
        codex_error_info: "server_overloaded",
      })}\n\n`,
      `data: ${JSON.stringify({ type: "response.output_text.delta", delta: "ok" })}\n\n`,
    ];
    const response = await capacityProxy((async () => new Response(bodies.shift()!, {
      status: 200,
      headers: { "content-type": "text/event-stream" },
    })) as typeof fetch)(responsesRequest());
    expect(response.status).toBe(200);
    expect(await response.text()).toContain('"delta":"ok"');
    expect(cooldowns).toEqual(["acct-capacity"]);
  });

  test("fails over a usage_limit_exceeded response before exposing it", async () => {
    const bodies = [
      JSON.stringify({
        error: {
          code: "usage_limit_exceeded",
          message: "You've hit your usage limit.",
        },
      }),
      `data: ${JSON.stringify({ type: "response.output_text.delta", delta: "ok" })}\n\n`,
    ];
    const statuses = [400, 200];
    const response = await capacityProxy((async () => new Response(bodies.shift()!, {
      status: statuses.shift()!,
      headers: { "content-type": "application/json" },
    })) as typeof fetch)(responsesRequest());
    expect(response.status).toBe(200);
    expect(await response.text()).toContain('"delta":"ok"');
    expect(cooldowns).toEqual(["acct-capacity"]);
  });

  test("uses the provider reset instead of a generic minute for a 429 quota", async () => {
    const bodies = [
      JSON.stringify({
        error: {
          type: "usage_limit_reached",
          resets_in_seconds: 7_200,
        },
      }),
      `data: ${JSON.stringify({ type: "response.output_text.delta", delta: "ok" })}\n\n`,
    ];
    const statuses = [429, 200];
    const response = await capacityProxy((async () => new Response(bodies.shift()!, {
      status: statuses.shift()!,
      headers: { "content-type": "application/json" },
    })) as typeof fetch)(responsesRequest());
    expect(response.status).toBe(200);
    expect(capacityCooldowns).toEqual([{
      accountId: "acct-capacity",
      durationMs: 7_200_000,
      failureCode: "usage_limit_exceeded",
    }]);
  });

  test("fails over a capacity event in an NDJSON response", async () => {
    const bodies = [
      `${[
        JSON.stringify({ type: "response.created" }),
        JSON.stringify({ type: "error", code: "usage_limit_reached" }),
      ].join("\n")}\n`,
      `${JSON.stringify({ type: "response.output_text.delta", delta: "ok" })}\n`,
    ];
    const response = await capacityProxy((async () => new Response(bodies.shift()!, {
      status: 200,
      headers: { "content-type": "application/x-ndjson" },
    })) as typeof fetch)(responsesRequest());
    expect(response.status).toBe(200);
    expect(await response.text()).toContain('"delta":"ok"');
    expect(cooldowns).toEqual(["acct-capacity"]);
  });

  test("fails over an NDJSON capacity event split across chunks", async () => {
    const record = JSON.stringify({ type: "error", code: "usage_limit_reached" });
    const encoder = new TextEncoder();
    const response = await capacityProxy((async () => new Response(new ReadableStream<Uint8Array>({
      start(controller) {
        controller.enqueue(encoder.encode(record.slice(0, -4)));
        controller.enqueue(encoder.encode(record.slice(-4) + "\n"));
        controller.close();
      },
    }), { status: 200, headers: { "content-type": "application/x-ndjson" } })) as typeof fetch)(responsesRequest());
    expect(response.status).toBe(200);
    expect(await response.text()).toContain('"delta":"ok"');
    expect(cooldowns).toEqual(["acct-capacity"]);
  });

  test("does not fail over when output text contains a capacity marker", async () => {
    const body = `data: ${JSON.stringify({
      type: "response.output_text.delta",
      delta: "the literal code is rate_limit_exceeded",
    })}\n\n`;
    const response = await capacityProxy((async () => new Response(body, {
      status: 200,
      headers: { "content-type": "text/event-stream" },
    })) as typeof fetch)(responsesRequest());
    expect(response.status).toBe(200);
    expect(await response.text()).toBe(body);
    expect(cooldowns).toEqual([]);
  });

  test("preserves complete NDJSON streams without failover", async () => {
    const body = `${[
      JSON.stringify({ type: "response.created" }),
      JSON.stringify({ type: "response.output_text.delta", delta: "full" }),
    ].join("\n")}\n`;
    const response = await capacityProxy((async () => new Response(body, {
      status: 200,
      headers: { "content-type": "application/x-ndjson; charset=utf-8" },
    })) as typeof fetch)(responsesRequest());
    expect(response.status).toBe(200);
    expect(await response.text()).toBe(body);
    expect(cooldowns).toEqual([]);
  });

  test("preserves an unterminated final NDJSON record at EOF", async () => {
    const body = JSON.stringify({ type: "response.output_text.delta", delta: "full" });
    const response = await capacityProxy((async () => new Response(body, {
      status: 200,
      headers: { "content-type": "application/x-ndjson" },
    })) as typeof fetch)(responsesRequest());
    expect(response.status).toBe(200);
    expect(await response.text()).toBe(body);
    expect(cooldowns).toEqual([]);
  });

  test("fails over a capacity response returned as a non-2xx JSON body", async () => {
    const bodies = [
      JSON.stringify({ error: { code: "model_capacity", message: "Selected model is at capacity" } }),
      `data: ${JSON.stringify({ type: "response.output_text.delta", delta: "ok" })}\n\n`,
    ];
    const statuses = [503, 200];
    const response = await capacityProxy((async () => new Response(bodies.shift()!, {
      status: statuses.shift()!,
      headers: { "content-type": "application/json" },
    })) as typeof fetch)(responsesRequest());
    expect(response.status).toBe(200);
    expect(await response.text()).toContain('"delta":"ok"');
    expect(cooldowns).toEqual(["acct-capacity"]);
  });

  test("treats response.created as metadata and preserves the complete stream", async () => {
    const body = [
      `data: ${JSON.stringify({ type: "response.created" })}\n\n`,
      `data: ${JSON.stringify({ type: "response.output_text.delta", delta: "full" })}\n\n`,
    ].join("");
    const response = await capacityProxy((async () => new Response(body, {
      status: 200,
      headers: { "content-type": "text/event-stream" },
    })) as typeof fetch)(responsesRequest());
    expect(response.status).toBe(200);
    expect(await response.text()).toBe(body);
    expect(cooldowns).toEqual([]);
  });

  test("hands a quiet pre-output stream back after a bounded probe", async () => {
    const body = [
      `data: ${JSON.stringify({ type: "response.created" })}\n\n`,
      `data: ${JSON.stringify({ type: "response.output_text.delta", delta: "late" })}\n\n`,
    ];
    const response = await capacityProxy((async () => new Response(new ReadableStream<Uint8Array>({
      async start(controller) {
        controller.enqueue(new TextEncoder().encode(body[0]!));
        await new Promise<void>((resolve) => setTimeout(resolve, 600));
        controller.enqueue(new TextEncoder().encode(body[1]!));
        controller.close();
      },
    }), { status: 200, headers: { "content-type": "text/event-stream" } })) as typeof fetch)(responsesRequest());
    expect(response.status).toBe(200);
    expect(await response.text()).toBe(body.join(""));
  });

  test("passes the session_id header to account selection", async () => {
    accountsToServe = [{ id: "acct-1", sticky: true }];
    const response = await proxy(responsesRequest({ session_id: "session-abc" }));
    expect(response.status).toBe(200);
    expect(selectInputs).toHaveLength(1);
    expect(selectInputs[0]?.sessionKey).toBe("session-abc");
    expect(selectInputs[0]?.teamId).toBe("team-1");
    // The Responses surface pools Codex sign-ins with OpenAI and OpenRouter keys.
    expect(selectInputs[0]?.provider).toEqual(["codex", "openai-apikey", "openrouter-apikey"]);
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
        return { id, provider: "codex" as const, vaultRevision: 1, credentialExpiresAt: null, sticky: false };
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
      select: async () => ({ id: "acct-1", provider: "codex" as const, vaultRevision: 1, credentialExpiresAt: null, sticky: false }),
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
        return { id, provider: "codex" as const, vaultRevision: 1, credentialExpiresAt: null, sticky: false };
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
        return { id: "acct-1", provider: "codex" as const, vaultRevision: 1, credentialExpiresAt: null };
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

  test("a VM header cannot substitute an unbound token", async () => {
    accountsToServe = [{ id: "acct-1", sticky: false }];
    const response = await proxy(responsesRequest({ "x-cmux-vm-id": "vm-9" }));
    expect(response.status).toBe(401);
    expect(selectInputs).toHaveLength(0);
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
