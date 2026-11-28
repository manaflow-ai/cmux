import { afterEach, describe, expect, mock, test } from "bun:test";
import { procedureResponse } from "./helpers/dashboard-procedure";

type SessionUser = {
  id: string;
  displayName?: string | null;
  primaryEmail?: string | null;
  primaryEmailVerified?: boolean;
  profileImageUrl?: string | null;
  selectedTeam?: { id: string } | null;
};

class AuthorizationUnavailable extends Error {}

let stackConfigured = true;
let outcome: SessionUser | null | Error = null;
const previousVault = process.env.CMUX_VAULT_ENABLED;

mock.module("@/app/lib/stack", () => ({
  isStackConfigured: () => stackConfigured,
  getStackServerApp: () => ({}),
}));

const realAuth = await import("../services/vms/auth");
mock.module("@/services/vms/auth", () => ({
  ...realAuth,
  verifyBrowserSessionRequest: async () => {
    if (outcome instanceof Error) throw outcome;
    return outcome;
  },
  withSubrouterAuthorizationDeadline: async (operation: (signal: AbortSignal) => Promise<unknown>) =>
    operation(new AbortController().signal),
  isSubrouterAuthorizationError: (error: unknown) => error instanceof AuthorizationUnavailable,
}));

const { accountRouter } = await import("../orpc/server/dashboard/account");
const GET = (request: Request) => procedureResponse(accountRouter.session, undefined, request);

function request() {
  return new Request("https://cmux.test/api/dashboard/session");
}

afterEach(() => {
  stackConfigured = true;
  outcome = null;
  if (previousVault === undefined) delete process.env.CMUX_VAULT_ENABLED;
  else process.env.CMUX_VAULT_ENABLED = previousVault;
});

describe("dashboard.account.session", () => {
  test("401 without a signed-in user", async () => {
    const response = await GET(request());
    expect(response.status).toBe(401);
    expect(await response.json()).toEqual({ error: { code: "unauthorized" } });
  });

  test("503 when Stack cannot confirm the session", async () => {
    outcome = new AuthorizationUnavailable("stack down");
    const response = await GET(request());
    expect(response.status).toBe(503);
    expect(await response.json()).toEqual({ error: { code: "authorization_unavailable" } });
  });

  test("unexpected verification failures propagate", async () => {
    outcome = new Error("bug");
    await expect(GET(request())).rejects.toThrow("bug");
  });

  test("404 when Stack is not configured", async () => {
    stackConfigured = false;
    const response = await GET(request());
    expect(response.status).toBe(404);
    expect(await response.json()).toEqual({ error: { code: "not_configured" } });
  });

  test("200 returns only the wire fields and the Vault flag, never cached", async () => {
    process.env.CMUX_VAULT_ENABLED = "true";
    outcome = {
      id: "user-1",
      displayName: "User One",
      primaryEmail: "user@example.com",
      primaryEmailVerified: true,
      profileImageUrl: "https://img.test/a.png",
      selectedTeam: { id: "team-1" },
    };
    const response = await GET(request());
    expect(response.status).toBe(200);
    expect(await response.json()).toEqual({
      user: {
        id: "user-1",
        displayName: "User One",
        primaryEmail: "user@example.com",
        primaryEmailVerified: true,
        profileImageUrl: "https://img.test/a.png",
        selectedTeamId: "team-1",
      },
      flags: { vaultEnabled: true },
    });
  });

  test("200 normalizes missing optional fields to null and false", async () => {
    process.env.CMUX_VAULT_ENABLED = "false";
    outcome = { id: "user-2" };
    const response = await GET(request());
    expect(await response.json()).toEqual({
      user: {
        id: "user-2",
        displayName: null,
        primaryEmail: null,
        primaryEmailVerified: false,
        profileImageUrl: null,
        selectedTeamId: null,
      },
      flags: { vaultEnabled: false },
    });
  });
});
