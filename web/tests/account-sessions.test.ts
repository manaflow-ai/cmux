import { describe, expect, mock, test } from "bun:test";
import { NextRequest } from "next/server";

process.env.SKIP_ENV_VALIDATION = "1";

const {
  ACCOUNT_SESSIONS_COOKIE,
  ACCOUNT_SESSIONS_PATH,
  dropSession,
  openSessions,
  saveSession,
  sealSessions,
} = await import("../app/handler/account-sessions");
const { ACCOUNT_HISTORY_LIMIT } = await import("../app/handler/sign-in-entry");
const { makeAccountsHandler } = await import("../app/handler/accounts/[action]/handler");
const { tokenSignIn } = await import("../app/handler/account-sessions-client");

const SECRET = "test-secret-key";
const ORIGIN = "https://cmux.test";
const COOKIE = `__Secure-${ACCOUNT_SESSIONS_COOKIE}`;

const a = { id: "user-a", refreshToken: "refresh-a", savedAt: 1 };
const b = { id: "user-b", refreshToken: "refresh-b", savedAt: 2 };

describe("the sealed session list", () => {
  test("round trips, newest first, one per account, capped", () => {
    let sessions = saveSession([], a);
    sessions = saveSession(sessions, b);
    sessions = saveSession(sessions, { ...a, refreshToken: "refresh-a2", savedAt: 3 });
    expect(sessions.map((entry) => entry.id)).toEqual(["user-a", "user-b"]);
    expect(openSessions(sealSessions(sessions, SECRET), SECRET)).toEqual(sessions);

    for (let index = 0; index < ACCOUNT_HISTORY_LIMIT + 2; index += 1) {
      sessions = saveSession(sessions, { id: `user-${index}`, refreshToken: `r${index}`, savedAt: 10 + index });
    }
    expect(sessions).toHaveLength(ACCOUNT_HISTORY_LIMIT);
    expect(dropSession(sessions, sessions[0].id)).toHaveLength(ACCOUNT_HISTORY_LIMIT - 1);
  });

  test("the tokens are not readable in the sealed value", () => {
    const sealed = sealSessions([a, b], SECRET);
    expect(sealed).not.toContain("refresh-a");
    expect(Buffer.from(sealed.slice(3), "base64url").toString("latin1")).not.toContain("refresh-a");
  });

  test("a tampered value, another key or a foreign value reads as no sessions", () => {
    const sealed = sealSessions([a], SECRET);
    const flipped = `${sealed.slice(0, -2)}${sealed.at(-2) === "A" ? "B" : "A"}${sealed.at(-1)}`;
    expect(openSessions(flipped, SECRET)).toEqual([]);
    expect(openSessions(sealed, "another-secret")).toEqual([]);
    expect(openSessions("v1.not-sealed", SECRET)).toEqual([]);
    expect(openSessions('[["user-a","refresh-a",1]]', SECRET)).toEqual([]);
    expect(openSessions(null, SECRET)).toEqual([]);
  });
});

type Lookup = { status: "valid"; id: string; tokens: { accessToken: string; refreshToken: string } } | { status: "invalid" };

function harness(options: {
  sessions?: typeof a[];
  current?: { id: string; refreshToken: string } | null;
  lookup?: (refreshToken: string) => Promise<Lookup>;
} = {}) {
  const revoke = mock(async (refreshToken: string) => {
    void refreshToken;
  });
  const lookup = mock(
    options.lookup ??
      (async (refreshToken: string): Promise<Lookup> => ({
        status: "valid",
        id: refreshToken.replace("refresh-", "user-"),
        tokens: { accessToken: `access-for-${refreshToken}`, refreshToken },
      })),
  );
  const handler = makeAccountsHandler({
    secret: SECRET,
    currentSession: async () => options.current ?? null,
    lookup,
    revoke,
    now: () => 100,
  });

  async function call(action: string, body: unknown = {}, headers: Record<string, string> = {}) {
    const cookie = options.sessions ? `${COOKIE}=${sealSessions(options.sessions, SECRET)}` : "";
    const request = new NextRequest(`${ORIGIN}/handler/accounts/${action}`, {
      method: "POST",
      body: JSON.stringify(body),
      headers: {
        "content-type": "application/json",
        "sec-fetch-site": "same-origin",
        origin: ORIGIN,
        ...(cookie ? { cookie } : {}),
        ...headers,
      },
    });
    const response = await handler(request, { params: Promise.resolve({ action }) });
    const setCookie = response.headers.get("set-cookie");
    const written = setCookie?.match(new RegExp(`${COOKIE}=([^;]*)`))?.[1];
    return {
      status: response.status,
      body: (await response.json()) as Record<string, unknown>,
      setCookie,
      saved: written === undefined ? null : openSessions(written, SECRET),
    };
  }
  return { call, lookup, revoke };
}

describe("account session routes", () => {
  test("only the sign-in page's own JSON fetches get in", async () => {
    const { call } = harness({ sessions: [a] });
    expect((await call("check", {}, { "sec-fetch-site": "cross-site" })).status).toBe(403);
    expect((await call("check", {}, { "sec-fetch-site": "same-site" })).status).toBe(403);
    expect((await call("check", {}, { "content-type": "text/plain" })).status).toBe(403);
    expect((await call("nope")).status).toBe(404);
  });

  test("the cookie is httpOnly, Secure, strict and scoped to these routes", async () => {
    const { setCookie } = await harness({ current: { id: "user-a", refreshToken: "refresh-a" } }).call("save");
    expect(setCookie).toContain(`Path=${ACCOUNT_SESSIONS_PATH}`);
    expect(setCookie).toContain("HttpOnly");
    expect(setCookie).toContain("Secure");
    expect(setCookie?.toLowerCase()).toContain("samesite=strict");
  });

  test("save keeps the browser's current session", async () => {
    const { saved } = await harness({ sessions: [b], current: { id: "user-a", refreshToken: "refresh-a" } }).call("save");
    expect(saved?.map((entry) => entry.id)).toEqual(["user-a", "user-b"]);
  });

  test("check drops ended sessions but keeps any the service could not answer for", async () => {
    const { body, saved } = await harness({
      sessions: [a, b, { id: "user-c", refreshToken: "refresh-c", savedAt: 3 }],
      lookup: async (refreshToken) => {
        if (refreshToken === "refresh-b") return { status: "invalid" };
        if (refreshToken === "refresh-c") throw new Error("service timeout");
        return { status: "valid", id: "user-a", tokens: { accessToken: "x", refreshToken } };
      },
    }).call("check");
    expect(body.signedIn).toEqual(["user-a", "user-c"]);
    expect(saved?.map((entry) => entry.id)).toEqual(["user-a", "user-c"]);
  });

  test("switch hands back the account's tokens and keeps the one it leaves", async () => {
    const routes = harness({ sessions: [b], current: { id: "user-a", refreshToken: "refresh-a" } });
    const { body, saved } = await routes.call("switch", { accountId: "user-b" });
    const lookup = routes.lookup;
    expect(body).toEqual({ status: "ok", tokens: { accessToken: "access-for-refresh-b", refreshToken: "refresh-b" } });
    expect(lookup).toHaveBeenCalledWith("refresh-b");
    expect(saved?.map((entry) => entry.id)).toEqual(["user-b", "user-a"]);
  });

  test("an account with no saved session is signed out", async () => {
    const { body } = await harness({ sessions: [a] }).call("switch", { accountId: "user-b" });
    expect(body).toEqual({ status: "signed-out" });
  });

  test("an ended session is dropped and nothing is handed back", async () => {
    const { body, saved } = await harness({ sessions: [a, b], lookup: async () => ({ status: "invalid" }) }).call("switch", { accountId: "user-b" });
    expect(body).toEqual({ status: "signed-out" });
    expect(saved?.map((entry) => entry.id)).toEqual(["user-a"]);
  });

  // The wrong-account guard: a token that now resolves to someone else is
  // never handed back, so a switch can't sign the browser into another account.
  test("a saved token that resolves to a different account is dropped, never used", async () => {
    const { body, saved } = await harness({
      sessions: [a, b],
      lookup: async () => ({ status: "valid", id: "user-z", tokens: { accessToken: "z", refreshToken: "refresh-b" } }),
    }).call("switch", { accountId: "user-b" });
    expect(body).toEqual({ status: "signed-out" });
    expect(JSON.stringify(body)).not.toContain("refresh-b");
    expect(saved?.map((entry) => entry.id)).toEqual(["user-a"]);
  });

  test("a service failure during a switch keeps the session for next time", async () => {
    const { body, setCookie } = await harness({
      sessions: [b],
      lookup: async () => {
        throw new Error("service timeout");
      },
    }).call("switch", { accountId: "user-b" });
    expect(body).toEqual({ status: "error" });
    expect(setCookie).toBeNull();
  });

  test("a malformed account id is refused", async () => {
    expect((await harness({ sessions: [a] }).call("switch", { accountId: "../x" })).status).toBe(400);
    expect((await harness({ sessions: [a] }).call("forget", {})).status).toBe(400);
  });

  test("forget ends that one session; forget-all ends every one and clears the cookie", async () => {
    const one = harness({ sessions: [a, b] });
    const forgot = await one.call("forget", { accountId: "user-b" });
    expect(one.revoke).toHaveBeenCalledWith("refresh-b");
    expect(forgot.saved?.map((entry) => entry.id)).toEqual(["user-a"]);

    const all = harness({ sessions: [a, b] });
    const cleared = await all.call("forget-all");
    expect(all.revoke.mock.calls.map(([token]) => token).sort()).toEqual(["refresh-a", "refresh-b"]);
    expect(cleared.setCookie).toContain("Max-Age=0");
  });
});

// The switch signs the browser in through a step the SDK doesn't publish. If
// an upgrade renames it, this fails before release; at runtime the chooser
// falls back to signing in again rather than breaking.
describe("the SDK's token sign-in step", () => {
  test("still exists on the client app", async () => {
    const { StackClientApp } = await import("@hexclave/next");
    const app = new StackClientApp({
      projectId: "00000000-0000-4000-8000-000000000000",
      publishableClientKey: "test-publishable-key",
      tokenStore: "memory",
    });
    expect(tokenSignIn(app)).not.toBeNull();
    expect(tokenSignIn({})).toBeNull();
  });
});

describe("account session routes: housekeeping", () => {
  test("forget-all leaves the browser's own session to the SDK's sign-out", async () => {
    const routes = harness({ sessions: [a, b], current: { id: "user-a", refreshToken: "refresh-a" } });
    await routes.call("forget-all");
    expect(routes.revoke.mock.calls.map(([token]) => token)).toEqual(["refresh-b"]);
  });

  test("a session pushed off the end of the list, or replaced, is ended", async () => {
    const full = Array.from({ length: ACCOUNT_HISTORY_LIMIT }, (_, index) => ({ id: `user-${index}`, refreshToken: `r${index}`, savedAt: index }));
    const pushed = harness({ sessions: full, current: { id: "user-new", refreshToken: "r-new" } });
    const { saved } = await pushed.call("save");
    expect(saved).toHaveLength(ACCOUNT_HISTORY_LIMIT);
    expect(pushed.revoke.mock.calls.map(([token]) => token)).toEqual([`r${ACCOUNT_HISTORY_LIMIT - 1}`]);

    const replaced = harness({ sessions: [a], current: { id: "user-a", refreshToken: "refresh-a-new" } });
    await replaced.call("save");
    expect(replaced.revoke.mock.calls.map(([token]) => token)).toEqual(["refresh-a"]);
  });
});
