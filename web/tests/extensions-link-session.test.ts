import { describe, expect, mock, test } from "bun:test";

class AuthorizationUnavailable extends Error {}
const SIGN_IN = "/handler/sign-in?after_auth_return_to=%2Fextensions%2Flink";

mock.module("../app/env", () => ({ env: { NEXT_PUBLIC_STACK_PROJECT_ID: "project-id" } }));
mock.module("@/services/vms/routeHelpers", () => ({ browserMutationOriginAllowed: () => false }));
mock.module("@/services/vms/auth", () => ({
  verifyBrowserSessionRequest: async () => { throw new AuthorizationUnavailable("stack down"); },
  withSubrouterAuthorizationDeadline: async <T>(operation: (signal: AbortSignal) => Promise<T>) => operation(new AbortController().signal),
  isSubrouterAuthorizationError: (error: unknown) => error instanceof AuthorizationUnavailable,
}));
mock.module("../app/lib/stack", () => ({ getStackServerApp: () => ({}) }));
mock.module("../app/lib/dashboard-auth", () => ({ readJoinViewer: async () => ({ kind: "signed_out" }) }));
mock.module("../app/lib/vault-auth", () => ({ vaultSignInHref: () => SIGN_IN }));
mock.module("../services/auth/stackTelemetry", () => ({ withStackAuthSpan: async <T>(_name: string, operation: () => Promise<T>) => operation() }));
mock.module("next/cache", () => ({ cacheLife: () => {} }));
mock.module("next/navigation", () => ({ unstable_rethrow: () => {} }));

const { resolveLinkSession } = await import("../app/extensions/_lib/link-session");

describe("extensions link session", () => {
  test("rejects a cross-origin mutation before checking auth", async () => {
    const response = await resolveLinkSession(new Request("https://cmux.test/api/extensions/link", {
      method: "POST",
      headers: { origin: "https://evil.test" },
    }));
    expect(response.status).toBe(403);
    expect(await response.json()).toEqual({ code: "extension.forbidden", message: "Link a repo from cmux.com." });
  });

  test("returns unavailable when Stack cannot confirm the session", async () => {
    const response = await resolveLinkSession(new Request("https://cmux.test/api/extensions/link"));
    expect(response.status).toBe(503);
    expect(await response.json()).toEqual({
      code: "extension.unavailable",
      message: "cmux sign-in could not be checked. Try again in a minute.",
    });
  });
});
