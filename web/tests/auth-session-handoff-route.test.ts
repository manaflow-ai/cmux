import { beforeEach, describe, expect, mock, test } from "bun:test";

type TestSession = {
  getTokens: () => Promise<{ accessToken?: string | null; refreshToken?: string | null }>;
};
type TestUser = {
  id: string;
  isAnonymous?: boolean;
  createSession: (options: { expiresInMillis: number }) => Promise<TestSession>;
};

let currentUser: TestUser | null = null;
let stackUnavailable = false;
let mintedTokens: { accessToken?: string | null; refreshToken?: string | null } = {};
let mintFails = false;

const createSession = mock(async (options: { expiresInMillis: number }): Promise<TestSession> => {
  void options;
  if (mintFails) throw new Error("Stack createSession failed");
  return { getTokens: async () => mintedTokens };
});
const getUser = mock(async (options: unknown): Promise<TestUser | null> => {
  void options;
  if (stackUnavailable) throw new Error("Stack Auth unavailable");
  return currentUser;
});

mock.module("../app/lib/stack", () => ({
  getStackServerApp: () => ({ getUser }),
  isStackConfigured: () => true,
  stackServerApp: { getUser },
}));

const { POST, SESSION_HANDOFF_LIFETIME_MS } = await import(
  "../app/api/auth/session-handoff/route"
);

const NATIVE_HEADERS = {
  authorization: "Bearer caller-access",
  "x-stack-refresh-token": "caller-refresh",
  "content-type": "application/json",
};
const VALID_BODY = { recipient: { bundleId: "com.cmuxterm.app.debug.next.my-tag", tag: "my-tag" } };

function handoffRequest(
  body: unknown = VALID_BODY,
  headers: Record<string, string> = NATIVE_HEADERS,
): Request {
  return new Request("https://cmux.com/api/auth/session-handoff", {
    method: "POST",
    headers,
    body: typeof body === "string" ? body : JSON.stringify(body),
  });
}

describe("POST /api/auth/session-handoff", () => {
  beforeEach(() => {
    currentUser = { id: "user-1", isAnonymous: false, createSession };
    stackUnavailable = false;
    mintFails = false;
    mintedTokens = { accessToken: "new-access", refreshToken: "new-refresh" };
    createSession.mockClear();
    getUser.mockClear();
  });

  test("the lifetime is seven days", () => {
    expect(SESSION_HANDOFF_LIFETIME_MS).toBe(7 * 24 * 60 * 60 * 1000);
  });

  test("mints a new session for the caller and returns its pair with an ISO expiry", async () => {
    const before = Date.now();
    const response = await POST(handoffRequest());
    const after = Date.now();

    expect(response.status).toBe(200);
    expect(response.headers.get("cache-control")).toBe("no-store");
    const body = (await response.json()) as Record<string, string>;
    expect(Object.keys(body).sort()).toEqual(["accessToken", "expiresAt", "refreshToken"]);
    expect(body.accessToken).toBe("new-access");
    expect(body.refreshToken).toBe("new-refresh");
    const expiresAt = Date.parse(body.expiresAt);
    expect(new Date(expiresAt).toISOString()).toBe(body.expiresAt);
    expect(expiresAt).toBeGreaterThanOrEqual(before + SESSION_HANDOFF_LIFETIME_MS);
    expect(expiresAt).toBeLessThanOrEqual(after + SESSION_HANDOFF_LIFETIME_MS);

    expect(getUser).toHaveBeenCalledWith({
      tokenStore: { accessToken: "caller-access", refreshToken: "caller-refresh" },
    });
    // The server-side user for the caller's id is the one that mints.
    expect(getUser).toHaveBeenLastCalledWith("user-1");
    expect(createSession).toHaveBeenCalledTimes(1);
    expect(createSession).toHaveBeenCalledWith({ expiresInMillis: SESSION_HANDOFF_LIFETIME_MS });
  });

  test("accepts a null tag", async () => {
    const response = await POST(
      handoffRequest({ recipient: { bundleId: "com.cmuxterm.app.debug.next", tag: null } }),
    );
    expect(response.status).toBe(200);
  });

  test("401 without native auth headers, before reading the body or calling Stack", async () => {
    const partialHeaders: Record<string, string>[] = [
      { "content-type": "application/json" },
      { authorization: "Bearer caller-access" },
      { "x-stack-refresh-token": "caller-refresh" },
      { authorization: "Basic abc", "x-stack-refresh-token": "caller-refresh" },
    ];
    for (const headers of partialHeaders) {
      // An unparseable body proves the body is never read before the 401.
      const response = await POST(handoffRequest("{not json", headers));
      expect(response.status).toBe(401);
      expect(await response.json()).toEqual({ error: "unauthorized" });
    }
    expect(getUser).not.toHaveBeenCalled();
    expect(createSession).not.toHaveBeenCalled();
  });

  test("401 when the tokens resolve to no user or an anonymous one", async () => {
    currentUser = null;
    expect((await POST(handoffRequest("{not json"))).status).toBe(401);

    currentUser = { id: "anon", isAnonymous: true, createSession };
    expect((await POST(handoffRequest("{not json"))).status).toBe(401);
    expect(createSession).not.toHaveBeenCalled();
  });

  test("503 when Stack Auth is unavailable", async () => {
    stackUnavailable = true;
    const response = await POST(handoffRequest());
    expect(response.status).toBe(503);
    expect(createSession).not.toHaveBeenCalled();
  });

  test("400 for a bad body", async () => {
    const bad: unknown[] = [
      "{not json",
      "[]",
      {},
      { recipient: null },
      { recipient: "com.cmuxterm.app" },
      { recipient: { tag: "x" } },
      { recipient: { bundleId: "", tag: null } },
      { recipient: { bundleId: "com.cmuxterm.app" } },
      { recipient: { bundleId: "com cmuxterm", tag: null } },
      { recipient: { bundleId: "com.cmuxterm.app/../x", tag: null } },
      { recipient: { bundleId: "a".repeat(256), tag: null } },
      { recipient: { bundleId: "com.cmuxterm.app", tag: "" } },
      { recipient: { bundleId: "com.cmuxterm.app", tag: "bad tag" } },
      { recipient: { bundleId: "com.cmuxterm.app", tag: "t".repeat(65) } },
      { recipient: { bundleId: "com.cmuxterm.app", tag: 7 } },
    ];
    for (const body of bad) {
      const response = await POST(handoffRequest(body));
      expect(response.status).toBe(400);
    }
    expect(createSession).not.toHaveBeenCalled();
  });

  test("413 for an oversized body", async () => {
    const response = await POST(
      handoffRequest({ recipient: { bundleId: "com.cmuxterm.app", tag: null }, pad: "x".repeat(8_000) }),
    );
    expect(response.status).toBe(413);
    expect(createSession).not.toHaveBeenCalled();
  });

  test("503 without tokens in the body or the log when minting fails", async () => {
    const logged: unknown[] = [];
    const originalError = console.error;
    console.error = (...args: unknown[]) => { logged.push(args); };
    try {
      mintFails = true;
      const failed = await POST(handoffRequest());
      expect(failed.status).toBe(503);
      expect(await failed.json()).toEqual({ error: "session_unavailable" });

      mintFails = false;
      mintedTokens = { accessToken: "new-access", refreshToken: null };
      const incomplete = await POST(handoffRequest());
      expect(incomplete.status).toBe(503);
      expect(JSON.stringify(await incomplete.json())).not.toContain("new-access");
    } finally {
      console.error = originalError;
    }
    const text = JSON.stringify(logged);
    for (const secret of ["caller-access", "caller-refresh", "new-access"]) {
      expect(text).not.toContain(secret);
    }
  });
});
