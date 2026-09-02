import { afterAll, beforeAll, beforeEach, describe, expect, mock, test } from "bun:test";

type SelectInput = {
  teamId: string;
  provider: string;
  sessionKey: string | null;
  excludedAccountIds?: readonly string[];
};

type UpstreamCall = {
  url: string;
  headers: Headers;
  body: unknown;
  signal: AbortSignal | null | undefined;
};

let selectInputs: SelectInput[] = [];
let accountsToServe: { id: string; sticky: boolean }[] = [];
let cooldowns: string[] = [];
let cooldownReasons: (string | undefined)[] = [];
let upstreamStatuses: number[] = [];
let upstreamCalls: UpstreamCall[] = [];
let credentialCalls: { accountId: string; force?: boolean }[] = [];

const originalFetch = globalThis.fetch;
beforeAll(() => {
  globalThis.fetch = mock(async (...args: unknown[]) => {
    const [url, init] = args as [string | URL | Request, RequestInit | undefined];
    const bodyBytes = init?.body as ArrayBuffer;
    upstreamCalls.push({
      url: String(url),
      headers: new Headers(init?.headers),
      body: bodyBytes && bodyBytes.byteLength > 0
        ? JSON.parse(new TextDecoder().decode(bodyBytes))
        : null,
      signal: init?.signal,
    });
    const status = upstreamStatuses.shift() ?? 200;
    return new Response('{"type":"message"}', {
      status,
      headers: { "content-type": "application/json" },
    });
  }) as typeof fetch;
});
afterAll(() => {
  globalThis.fetch = originalFetch;
});

const { createClaudeMessagesProxy, claudeSessionKey } = await import(
  "../services/coderouter/claudeProxy"
);

const proxy = createClaudeMessagesProxy({
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
  credential: async ({ accountId, force }) => {
    credentialCalls.push({ accountId, ...(force ? { force } : {}) });
    return {
      provider: "claude",
      accessToken: `claude-access-${accountId}${force ? "-forced" : ""}`,
      refreshToken: "refresh",
      accountId: "claude-provider-account",
      email: "person@example.com",
      expiresAt: Date.now() + 60_000,
    };
  },
  cooldown: async (accountId, _durationMs, reason) => {
    cooldowns.push(accountId);
    cooldownReasons.push(reason);
  },
});

beforeEach(() => {
  selectInputs = [];
  accountsToServe = [];
  cooldowns = [];
  cooldownReasons = [];
  upstreamStatuses = [];
  upstreamCalls = [];
  credentialCalls = [];
});

function messagesRequest(
  headers: Record<string, string> = {},
  body: unknown = {
    model: "claude-sonnet-5",
    max_tokens: 128,
    messages: [{ role: "user", content: "hello" }],
    metadata: { user_id: "user_abc_account_def_session_123" },
  },
): Request {
  return new Request("https://coderouter.dev/v1/messages", {
    method: "POST",
    headers: {
      authorization: "Bearer crt_token",
      "content-type": "application/json",
      "anthropic-version": "2023-06-01",
      "user-agent": "claude-cli/2.1.0 (external)",
      ...headers,
    },
    body: JSON.stringify(body),
  });
}

describe("claude messages proxy", () => {
  test("forwards to the Anthropic messages upstream with the leased OAuth bearer", async () => {
    accountsToServe = [{ id: "acct-1", sticky: true }];
    const response = await proxy(messagesRequest({ "x-api-key": "crt_token" }));
    expect(response.status).toBe(200);
    expect(upstreamCalls).toHaveLength(1);
    const call = upstreamCalls[0]!;
    expect(call.url).toBe("https://api.anthropic.com/v1/messages");
    expect(call.headers.get("authorization")).toBe("Bearer claude-access-acct-1");
    // The route token must never reach the provider; the OAuth beta must.
    expect(call.headers.get("x-api-key")).toBeNull();
    expect(call.headers.get("anthropic-beta")).toBe("oauth-2025-04-20");
    expect(call.headers.get("anthropic-version")).toBe("2023-06-01");
    expect(call.body).toMatchObject({ model: "claude-sonnet-5" });
  });

  test("the caller's abort propagates to the provider request", async () => {
    accountsToServe = [{ id: "acct-1", sticky: true }];
    const controller = new AbortController();
    const request = new Request("https://coderouter.dev/v1/messages", {
      method: "POST",
      headers: {
        authorization: "Bearer crt_token",
        "content-type": "application/json",
      },
      body: "{}",
      signal: controller.signal,
    });
    const response = await proxy(request);
    expect(response.status).toBe(200);
    const upstreamSignal = upstreamCalls[0]?.signal;
    expect(upstreamSignal?.aborted).toBe(false);
    controller.abort();
    // The signal handed to fetch must be the request's own (dependent)
    // signal, so a caller hang-up aborts the in-flight provider request.
    expect(upstreamSignal?.aborted).toBe(true);
  });

  test("appends the OAuth beta to client-sent beta capabilities", async () => {
    accountsToServe = [{ id: "acct-1", sticky: true }];
    await proxy(messagesRequest({ "anthropic-beta": "context-1m-2025-08-07" }));
    expect(upstreamCalls[0]?.headers.get("anthropic-beta")).toBe(
      "context-1m-2025-08-07,oauth-2025-04-20",
    );
  });

  test("keeps the session sticky on the body's metadata.user_id", async () => {
    accountsToServe = [{ id: "acct-1", sticky: true }];
    const response = await proxy(messagesRequest());
    expect(response.status).toBe(200);
    expect(selectInputs).toHaveLength(1);
    expect(selectInputs[0]?.provider).toBe("claude");
    expect(selectInputs[0]?.teamId).toBe("team-1");
    expect(selectInputs[0]?.sessionKey).toBe("user_abc_account_def_session_123");
  });

  test("a session header outranks the body metadata", async () => {
    accountsToServe = [{ id: "acct-1", sticky: true }];
    await proxy(messagesRequest({ "x-claude-code-session-id": "session-h" }));
    expect(selectInputs[0]?.sessionKey).toBe("session-h");
  });

  test("selects without a session key when neither header nor metadata exist", async () => {
    accountsToServe = [{ id: "acct-1", sticky: false }];
    await proxy(messagesRequest({}, { model: "claude-sonnet-5", messages: [] }));
    expect(selectInputs[0]?.sessionKey).toBeNull();
  });

  test("routes count_tokens through the same account plane", async () => {
    accountsToServe = [{ id: "acct-1", sticky: true }];
    const response = await proxy(messagesRequest(), "count_tokens");
    expect(response.status).toBe(200);
    expect(upstreamCalls[0]?.url).toBe(
      "https://api.anthropic.com/v1/messages/count_tokens",
    );
  });

  test("force-refreshes once and resends when the provider rejects the credential", async () => {
    accountsToServe = [{ id: "acct-1", sticky: true }];
    upstreamStatuses = [401, 200];
    const response = await proxy(messagesRequest());
    expect(response.status).toBe(200);
    expect(credentialCalls).toEqual([
      { accountId: "acct-1" },
      { accountId: "acct-1", force: true },
    ]);
    expect(upstreamCalls).toHaveLength(2);
    expect(upstreamCalls[1]?.headers.get("authorization")).toBe(
      "Bearer claude-access-acct-1-forced",
    );
  });

  test("an account still rejected after a forced refresh is cooled down and the session moves", async () => {
    accountsToServe = [
      { id: "acct-1", sticky: true },
      { id: "acct-2", sticky: false },
    ];
    upstreamStatuses = [401, 401, 200];
    const response = await proxy(messagesRequest());
    expect(response.status).toBe(200);
    expect(credentialCalls).toEqual([
      { accountId: "acct-1" },
      { accountId: "acct-1", force: true },
      { accountId: "acct-2" },
    ]);
    expect(cooldowns).toEqual(["acct-1"]);
    // Recorded as an auth failure, not a rate limit.
    expect(cooldownReasons).toEqual(["auth_rejected"]);
    expect(upstreamCalls).toHaveLength(3);
    expect(upstreamCalls[2]?.headers.get("authorization")).toBe(
      "Bearer claude-access-acct-2",
    );
  });

  test("cools down a rate-limited account and retries excluding it", async () => {
    accountsToServe = [
      { id: "acct-1", sticky: true },
      { id: "acct-2", sticky: false },
    ];
    upstreamStatuses = [429, 200];
    const response = await proxy(messagesRequest());
    expect(response.status).toBe(200);
    expect(cooldowns).toEqual(["acct-1"]);
    // Default reason: a rate limit.
    expect(cooldownReasons).toEqual([undefined]);
    expect(selectInputs).toHaveLength(2);
    expect(selectInputs[1]?.excludedAccountIds).toEqual(["acct-1"]);
  });

  test("treats an overloaded upstream (529) like a rate limit", async () => {
    accountsToServe = [
      { id: "acct-1", sticky: true },
      { id: "acct-2", sticky: false },
    ];
    upstreamStatuses = [529, 200];
    const response = await proxy(messagesRequest());
    expect(response.status).toBe(200);
    expect(cooldowns).toEqual(["acct-1"]);
  });

  test("a rate limit on the last account yields no_usable_account, never the discarded 429", async () => {
    accountsToServe = [{ id: "acct-1", sticky: true }];
    upstreamStatuses = [429];
    const response = await proxy(messagesRequest());
    expect(response.status).toBe(503);
    const body = await response.json() as { error: string };
    expect(body.error).toBe("no_usable_account");
    expect(cooldowns).toEqual(["acct-1"]);
  });

  test("a 401 that survives the forced refresh on the last account yields no_usable_account", async () => {
    accountsToServe = [{ id: "acct-1", sticky: true }];
    upstreamStatuses = [401, 401];
    const response = await proxy(messagesRequest());
    expect(response.status).toBe(503);
    const body = await response.json() as { error: string };
    expect(body.error).toBe("no_usable_account");
    expect(cooldownReasons).toEqual(["auth_rejected"]);
  });

  test("returns no_usable_account when selection is exhausted", async () => {
    accountsToServe = [];
    const response = await proxy(messagesRequest());
    expect(response.status).toBe(503);
    const body = await response.json() as { error: string; retryable: boolean };
    expect(body.error).toBe("no_usable_account");
    expect(body.retryable).toBe(true);
    expect(response.headers.get("retry-after")).toBe("15");
  });

  test("rejects a request without a route token", async () => {
    const request = new Request("https://coderouter.dev/v1/messages", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: "{}",
    });
    const response = await proxy(request);
    expect(response.status).toBe(401);
    expect(upstreamCalls).toHaveLength(0);
  });

  test("accepts the route token via the x-coderouter-route-token header", async () => {
    accountsToServe = [{ id: "acct-1", sticky: false }];
    const request = new Request("https://coderouter.dev/v1/messages", {
      method: "POST",
      headers: {
        "content-type": "application/json",
        "x-coderouter-route-token": "crt_token",
      },
      body: "{}",
    });
    const response = await proxy(request);
    expect(response.status).toBe(200);
  });
});

describe("claudeSessionKey", () => {
  const encode = (value: unknown): ArrayBuffer =>
    new TextEncoder().encode(JSON.stringify(value)).buffer as ArrayBuffer;

  test("reads metadata.user_id from the body", () => {
    expect(
      claudeSessionKey(new Headers(), encode({ metadata: { user_id: "u-1" } })),
    ).toBe("u-1");
  });

  test("ignores malformed bodies and oversized values", () => {
    expect(
      claudeSessionKey(
        new Headers(),
        new TextEncoder().encode("not json").buffer as ArrayBuffer,
      ),
    ).toBeNull();
    expect(
      claudeSessionKey(
        new Headers(),
        encode({ metadata: { user_id: "x".repeat(600) } }),
      ),
    ).toBeNull();
  });

  test("ignores oversized header values", () => {
    expect(
      claudeSessionKey(
        new Headers({ "x-claude-code-session-id": "y".repeat(600) }),
        encode({}),
      ),
    ).toBeNull();
  });
});
