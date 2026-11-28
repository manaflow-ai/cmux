import { beforeEach, describe, expect, mock, test } from "bun:test";

mock.module("next/cache", () => ({ cacheLife: () => {} }));

const authModule = await import("../services/vms/auth");

type Hooks = {
  user: { id: string } | null;
  verify: () => Promise<{ id: string } | null>;
  tokens: { accessToken?: string } | null;
};
const hooks: Hooks = { user: null, verify: async () => hooks.user, tokens: null };

mock.module("@/app/env", () => ({ env: { NEXT_PUBLIC_STACK_PROJECT_ID: "proj" } }));
mock.module("@/app/lib/dashboard-auth", () => ({ readJoinViewer: async () => ({ kind: "signed-out" }) }));
mock.module("@/app/lib/stack", () => ({ getStackServerApp: () => ({ getAuthJson: async () => hooks.tokens }) }));
mock.module("@/app/lib/vault-auth", () => ({ vaultSignInHref: (path: string) => `/handler/sign-in?return=${path}` }));
mock.module("@/services/auth/stackTelemetry", () => ({ withStackAuthSpan: (_name: string, run: () => unknown) => run() }));
mock.module("@/services/vms/auth", () => ({
  ...authModule,
  verifyBrowserSessionRequest: () => hooks.verify(),
}));

const { resolveLinkSession } = await import("../app/extensions/_lib/link-session");

const sameOrigin = (method: string) =>
  new Request("https://cmux.com/api/extensions/link", {
    method,
    headers: { origin: "https://cmux.com", "sec-fetch-site": "same-origin" },
  });

beforeEach(() => {
  hooks.user = { id: "stack-user" };
  hooks.verify = async () => hooks.user;
  hooks.tokens = { accessToken: "stack-access-token" };
});

describe("resolveLinkSession", () => {
  test("a POST or DELETE from another origin, or with no origin, is a 403 before Stack is asked", async () => {
    let asked = 0;
    hooks.verify = async () => {
      asked += 1;
      return hooks.user;
    };
    const requests = [
      new Request("https://cmux.com/api/extensions/link", { method: "POST", headers: { origin: "https://evil.test" } }),
      new Request("https://cmux.com/api/extensions/link", { method: "DELETE", headers: { origin: "https://cmux.com", "sec-fetch-site": "cross-site" } }),
      new Request("https://cmux.com/api/extensions/link", { method: "POST" }),
    ];
    for (const request of requests) {
      const result = await resolveLinkSession(request);
      expect(result.ok).toBe(false);
      if (result.ok) continue;
      expect(result.response.status).toBe(403);
      expect((await result.response.json()).code).toBe("extension.forbidden");
    }
    expect(asked).toBe(0);
  });

  test("a GET needs no origin and a signed-in person gets the access token and a personal team", async () => {
    const result = await resolveLinkSession(new Request("https://cmux.com/api/extensions/link"));
    expect(result.ok).toBe(true);
    if (!result.ok) return;
    expect(result.session.accessToken).toBe("stack-access-token");
    expect(result.session.team).toMatch(/^team_[0-9a-f]{20}$/);
  });

  test("a same-origin POST passes the origin check", async () => {
    expect((await resolveLinkSession(sameOrigin("POST"))).ok).toBe(true);
  });

  test("signed out, or a session with no access token, is a 401 with the sign-in URL", async () => {
    hooks.user = null;
    const signedOut = await resolveLinkSession(sameOrigin("POST"));
    expect(signedOut.ok).toBe(false);
    if (!signedOut.ok) expect(signedOut.response.status).toBe(401);

    hooks.user = { id: "stack-user" };
    hooks.tokens = {};
    const noToken = await resolveLinkSession(sameOrigin("POST"));
    expect(noToken.ok).toBe(false);
    if (!noToken.ok) {
      expect(noToken.response.status).toBe(401);
      expect((await noToken.response.json()).signInUrl).toContain("/extensions/link");
    }
  });

  test("a Stack failure is a 503 unavailable, and any other error is not swallowed", async () => {
    hooks.verify = async () => {
      throw new authModule.SubrouterAuthorizationUnavailableError("stack down");
    };
    const result = await resolveLinkSession(sameOrigin("POST"));
    expect(result.ok).toBe(false);
    if (!result.ok) {
      expect(result.response.status).toBe(503);
      expect((await result.response.json()).code).toBe("extension.unavailable");
    }

    hooks.verify = async () => {
      throw new TypeError("bug");
    };
    await expect(resolveLinkSession(sameOrigin("POST"))).rejects.toThrow("bug");
  });
});
