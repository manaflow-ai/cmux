import { afterEach, beforeEach, describe, expect, mock, test } from "bun:test";

let signedIn = true;
let pendingResult: "cmux-vault" | "subrouter" | null = "subrouter";
const pendingClient = mock(async (code: string): Promise<"cmux-vault" | "subrouter" | null> =>
  code ? pendingResult : null);

const realAuth = await import("../services/vms/auth");
mock.module("@/services/vms/auth", () => ({
  ...realAuth,
  verifyRequest: async () => (signedIn ? { id: "user-1" } : null),
}));
const realCliAuth = await import("../services/vault/cliAuth");
mock.module("@/services/vault/cliAuth", () => ({
  ...realCliAuth,
  pendingCliAuthClientForUserCode: pendingClient,
}));

const summaryRoute = await import("../app/api/vault/summary/route");
const clientRoute = await import("../app/api/vault/cli/auth/client/route");
const headRoute = await import("../app/api/vault/sessions/[id]/head/route");

const ORIGINAL_ENV = {
  CMUX_VAULT_ENABLED: process.env.CMUX_VAULT_ENABLED,
  CMUX_VAULT_S3_BUCKET: process.env.CMUX_VAULT_S3_BUCKET,
};

beforeEach(() => {
  signedIn = true;
  pendingClient.mockClear();
  pendingResult = "subrouter";
  process.env.CMUX_VAULT_ENABLED = "1";
  process.env.CMUX_VAULT_S3_BUCKET = "test-bucket";
});

afterEach(() => {
  for (const [key, value] of Object.entries(ORIGINAL_ENV)) {
    if (value === undefined) delete process.env[key];
    else process.env[key] = value;
  }
});

const get = (url: string) => new Request(`https://cmux.test${url}`);

describe("GET /api/vault/summary", () => {
  test("404 while the Vault release flag is off", async () => {
    process.env.CMUX_VAULT_ENABLED = "0";
    const response = await summaryRoute.GET(get("/api/vault/summary"));
    expect(response.status).toBe(404);
    expect(await response.json()).toEqual({ error: "vault_disabled" });
  });

  test("401 without a session", async () => {
    signedIn = false;
    expect((await summaryRoute.GET(get("/api/vault/summary"))).status).toBe(401);
  });
});

describe("GET /api/vault/sessions/[id]/head", () => {
  test("404 for a malformed id before touching storage", async () => {
    const response = await headRoute.GET(get("/api/vault/sessions/nope/head"), {
      params: Promise.resolve({ id: "nope" }),
    });
    expect(response.status).toBe(404);
  });

  test("404 while the Vault release flag is off", async () => {
    process.env.CMUX_VAULT_ENABLED = "0";
    const id = "11111111-1111-4111-8111-111111111111";
    const response = await headRoute.GET(get(`/api/vault/sessions/${id}/head`), {
      params: Promise.resolve({ id }),
    });
    expect(response.status).toBe(404);
  });
});

describe("GET /api/vault/cli/auth/client", () => {
  test("names the client of a pending request from its normalized code", async () => {
    const response = await clientRoute.GET(get("/api/vault/cli/auth/client?code=%20abcd2345%20"));
    expect(response.status).toBe(200);
    expect(await response.json()).toEqual({ client: "subrouter" });
    expect(pendingClient.mock.calls[0]?.[0]).toBe("ABCD2345");
  });

  test("null when no request is pending", async () => {
    pendingResult = null;
    const response = await clientRoute.GET(get("/api/vault/cli/auth/client?code=ABCD2345"));
    expect(await response.json()).toEqual({ client: null });
  });

  test.each(["", "SHORT", "ABCD1234", "ABCD23456"])("400 for an invalid code %p", async (code) => {
    const response = await clientRoute.GET(get(`/api/vault/cli/auth/client?code=${code}`));
    expect(response.status).toBe(400);
    expect(pendingClient).not.toHaveBeenCalled();
  });

  test("works with the Vault flag off, because CodeRouter uses it", async () => {
    process.env.CMUX_VAULT_ENABLED = "0";
    const response = await clientRoute.GET(get("/api/vault/cli/auth/client?code=ABCD2345"));
    expect(response.status).toBe(200);
  });

  test("401 without a session", async () => {
    signedIn = false;
    const response = await clientRoute.GET(get("/api/vault/cli/auth/client?code=ABCD2345"));
    expect(response.status).toBe(401);
  });
});
