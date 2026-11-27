import { afterEach, describe, expect, test } from "bun:test";
import { stackVmSession } from "./stack-vm-session.ts";

const realFetch = globalThis.fetch;
afterEach(() => {
  globalThis.fetch = realFetch;
});

function stub(routes: Record<string, { status: number; body: unknown }>, seen: string[] = []): void {
  globalThis.fetch = (async (input: string | URL | Request, init?: RequestInit) => {
    const url = String(input);
    const key = `${init?.method ?? "GET"} ${url.replace("https://api.stack-auth.com", "")}`;
    seen.push(key);
    const route = routes[key];
    return new Response(route ? JSON.stringify(route.body) : "{}", { status: route?.status ?? 404 });
  }) as typeof fetch;
}

describe("stackVmSession", () => {
  test("signs in and picks the cmux VM personal tenant", async () => {
    const seen: string[] = [];
    stub(
      {
        "POST /api/v1/auth/password/sign-in": { status: 200, body: { access_token: "at", refresh_token: "rt" } },
        "GET /api/v1/teams?user_id=me": { status: 200, body: { items: [{ id: "t-other" }, { id: "t-vm", client_read_only_metadata: { cmuxVmPersonalTenant: true } }] } },
        "GET /api/v1/users/me": { status: 200, body: { selected_team_id: "t-other" } },
      },
      seen,
    );
    const session = await stackVmSession("https://vm-staging.cmux.dev", "a@example.com", "pw");
    expect(session).toEqual({ access: "at", team: "t-vm", via: "the user's cmux VM personal tenant" });
    expect(seen[0]).toBe("POST /api/v1/auth/password/sign-in");
  });

  test("a failed sign-in names the status and code, never the password", async () => {
    stub({ "POST /api/v1/auth/password/sign-in": { status: 400, body: { code: "EMAIL_PASSWORD_MISMATCH" } } });
    const error = await stackVmSession("https://vm-staging.cmux.dev", "a@example.com", "s3cret").catch((e: Error) => e);
    expect(String(error)).toContain("HTTP 400 EMAIL_PASSWORD_MISMATCH");
    expect(String(error)).not.toContain("s3cret");
  });

  test("an origin with no known Stack project is refused before any call", async () => {
    const seen: string[] = [];
    stub({}, seen);
    await expect(stackVmSession("https://vm.cmux.dev", "a@example.com", "pw")).rejects.toThrow("no Stack project");
    expect(seen).toEqual([]);
  });

  test("an account in no team says why", async () => {
    stub({
      "POST /api/v1/auth/password/sign-in": { status: 200, body: { access_token: "at" } },
      "GET /api/v1/teams?user_id=me": { status: 200, body: { items: [] } },
    });
    await expect(stackVmSession("https://vm-staging.cmux.dev", "a@example.com", "pw")).rejects.toThrow("in no Stack team");
  });
});
