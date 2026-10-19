import { beforeEach, describe, expect, mock, test } from "bun:test";
import { call, ORPCError } from "@orpc/server";

let stackUser: Record<string, unknown> | null = null;
let allowUserApiKeys = true;

mock.module("@/services/billing/dashboardSessionRoute", () => ({
  resolveDashboardSessionUser: async () => ({ ok: true, user: { id: "user-1" } }),
}));

mock.module("@/app/lib/stack", () => ({
  isStackConfigured: () => true,
  getStackServerApp: () => ({
    getUser: async () => stackUser,
    getProject: async () => ({
      displayName: "cmux",
      config: {
        credentialEnabled: true,
        passkeyEnabled: false,
        magicLinkEnabled: true,
        allowUserApiKeys,
        clientUserDeletionEnabled: false,
        oauthProviders: [{ id: "github" }, { id: "google" }],
      },
    }),
  }),
}));

const { settingsRouter } = await import("../orpc/server/dashboard/settings");

const context = { request: new Request("https://cmux.test/dashboard/settings"), serverPrefetch: true };

beforeEach(() => {
  allowUserApiKeys = true;
  stackUser = {
    isAnonymous: false,
    listContactChannels: async () => [{
      id: "c1",
      value: "me@example.com",
      type: "email",
      isPrimary: true,
      isVerified: true,
      usedForAuth: true,
      delete: async () => undefined,
    }],
    listNotificationCategories: async () => [{ id: "n1", name: "Product", enabled: true, canDisable: false, setEnabled: async () => undefined }],
    getActiveSessions: async () => [{
      id: "s1",
      userId: "user-1",
      createdAt: new Date("2026-09-01T00:00:00.000Z"),
      lastUsedAt: undefined,
      isImpersonation: false,
      isCurrentSession: true,
      geoInfo: { ip: "203.0.113.1", cityName: "Portland" },
    }],
    listApiKeys: async () => [{
      id: "k1",
      description: "ci",
      createdAt: new Date("2026-09-02T00:00:00.000Z"),
      expiresAt: undefined,
      manuallyRevokedAt: new Date("2026-09-03T00:00:00.000Z"),
      value: { lastFour: "abcd" },
      whyInvalid: () => "manually-revoked",
    }],
    listOAuthProviders: async () => [{ id: "p1", type: "github", email: undefined, allowSignIn: true, allowConnectedAccounts: false }],
  };
});

describe("dashboard.settings", () => {
  test("overview returns the project sign-in flags and plain email rows", async () => {
    expect(await call(settingsRouter.overview, undefined, { context })).toEqual({
      project: {
        displayName: "cmux",
        credentialEnabled: true,
        passkeyEnabled: false,
        magicLinkEnabled: true,
        allowUserApiKeys: true,
        clientUserDeletionEnabled: false,
      },
      emails: [{ id: "c1", value: "me@example.com", type: "email", isPrimary: true, isVerified: true, usedForAuth: true }],
    });
  });

  test("lists serialize dates and computed key status", async () => {
    expect(await call(settingsRouter.notifications, undefined, { context })).toEqual([
      { id: "n1", name: "Product", enabled: true, canDisable: false },
    ]);
    expect(await call(settingsRouter.sessions, undefined, { context })).toEqual([{
      id: "s1",
      createdAt: "2026-09-01T00:00:00.000Z",
      lastUsedAt: null,
      isImpersonation: false,
      isCurrentSession: true,
      geoInfo: { ip: "203.0.113.1", cityName: "Portland", countryCode: null },
    }]);
    expect(await call(settingsRouter.apiKeys, undefined, { context })).toEqual([{
      id: "k1",
      description: "ci",
      createdAt: "2026-09-02T00:00:00.000Z",
      expiresAt: null,
      manuallyRevokedAt: "2026-09-03T00:00:00.000Z",
      lastFour: "abcd",
      whyInvalid: "manually-revoked",
    }]);
    expect(await call(settingsRouter.oauthProviders, undefined, { context })).toEqual({
      linked: [{ id: "p1", type: "github", email: null, allowSignIn: true, allowConnectedAccounts: false }],
      available: ["github", "google"],
    });
  });

  test("an anonymous or missing Stack user is a declared UNAUTHORIZED", async () => {
    for (const user of [null, { isAnonymous: true }]) {
      stackUser = user;
      const error = await call(settingsRouter.overview, undefined, { context }).catch((caught: unknown) => caught);
      expect(error).toBeInstanceOf(ORPCError);
      expect([(error as ORPCError<string, unknown>).code, (error as ORPCError<string, unknown>).status]).toEqual(["UNAUTHORIZED", 401]);
    }
  });

  test("API keys on a project without user API keys is a declared FORBIDDEN, not a server error", async () => {
    allowUserApiKeys = false;
    stackUser = { ...stackUser, listApiKeys: async () => { throw new Error("user API keys are not enabled"); } };
    const error = await call(settingsRouter.apiKeys, undefined, { context }).catch((caught: unknown) => caught);
    expect(error).toBeInstanceOf(ORPCError);
    const refusal = error as ORPCError<string, { reason: string }>;
    expect([refusal.code, refusal.status, refusal.data.reason]).toEqual(["FORBIDDEN", 403, "api_keys_disabled"]);
  });
});
