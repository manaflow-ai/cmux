import { describe, expect, test } from "bun:test";

import {
  handleGetRelayPreference,
  handlePutRelayPreference,
  type RelayPreferenceDeps,
} from "../app/api/relay/preferences/route";
import { RelayPreferenceConflictError } from "../services/relay/errors";
import type { RelayCatalog } from "../services/relay/model";
import type { AuthedUser } from "../services/vms/auth";

const CATALOG: RelayCatalog = {
  version: 1,
  sequence: 1,
  relays: [{
    id: "managed-one",
    provider: "cmux",
    region: "us-west",
    url: "https://relay-one.cmux.dev/",
  }],
};

function deps(overrides: Partial<RelayPreferenceDeps> = {}): RelayPreferenceDeps {
  return {
    verifyRequest: async () => ({ id: "account-a" }) as AuthedUser,
    catalog: () => CATALOG,
    getPreference: async () => ({ preference: { mode: "automatic" }, revision: 0 }),
    putPreference: async ({ preference }) => ({ preference, revision: 1 }),
    checkRateLimit: async () => ({ rateLimited: false }),
    rateLimitRuleId: () => undefined,
    isVercel: () => false,
    ...overrides,
  };
}

function getRequest(): Request {
  return new Request("https://cmux.dev/api/relay/preferences");
}

function putRequest(body: unknown): Request {
  return new Request("https://cmux.dev/api/relay/preferences", {
    method: "PUT",
    headers: { "content-type": "application/json" },
    body: JSON.stringify(body),
  });
}

describe("/api/relay/preferences", () => {
  test("GET reads only the authenticated account", async () => {
    let accountId: string | undefined;
    const response = await handleGetRelayPreference(getRequest(), deps({
      getPreference: async (value) => {
        accountId = value;
        return { preference: { mode: "automatic" }, revision: 8 };
      },
    }));
    expect(response.status).toBe(200);
    expect(accountId).toBe("account-a");
    expect(await response.json()).toEqual({
      preference: { mode: "automatic" },
      preferenceRevision: 8,
    });
  });

  test("PUT scopes the write to auth and persists custom metadata without secrets", async () => {
    let saved: Parameters<RelayPreferenceDeps["putPreference"]>[0] | undefined;
    const preference = {
      mode: "custom" as const,
      customRelays: [{
        id: "home-relay",
        provider: "self-hosted",
        region: "home",
        url: "https://relay.example.net/",
        displayName: "Home relay",
        authMode: "device_secret" as const,
      }],
    };
    const response = await handlePutRelayPreference(
      putRequest({ expectedRevision: 2, preference }),
      deps({
        putPreference: async (input) => {
          saved = input;
          return { preference: input.preference, revision: 3 };
        },
      }),
    );
    expect(response.status).toBe(200);
    expect(saved).toEqual({
      accountId: "account-a",
      expectedRevision: 2,
      preference,
      catalog: CATALOG,
    });
    expect(JSON.stringify(saved)).not.toContain("token");
  });

  test("rejects custom credentials before the repository sees them", async () => {
    let called = false;
    const response = await handlePutRelayPreference(
      putRequest({
        preference: {
          mode: "custom",
          customRelays: [{
            id: "home-relay",
            provider: "self-hosted",
            region: "home",
            url: "https://relay.example.net/",
            authMode: "device_secret",
            authToken: "plaintext-must-not-be-stored",
          }],
        },
      }),
      deps({
        putPreference: async ({ preference }) => {
          called = true;
          return { preference, revision: 1 };
        },
      }),
    );
    expect(response.status).toBe(400);
    expect(await response.json()).toEqual({ error: "credential_fields_forbidden" });
    expect(called).toBe(false);
  });

  test("returns revision conflicts and rate-limit failures as typed statuses", async () => {
    const conflict = await handlePutRelayPreference(
      putRequest({ expectedRevision: 2, preference: { mode: "automatic" } }),
      deps({
        putPreference: async () => {
          throw new RelayPreferenceConflictError({
            expectedRevision: 2,
            currentRevision: 4,
          });
        },
      }),
    );
    expect(conflict.status).toBe(409);
    expect(await conflict.json()).toEqual({
      error: "preference_conflict",
      currentRevision: 4,
    });

    const limited = await handleGetRelayPreference(getRequest(), deps({
      isVercel: () => true,
      rateLimitRuleId: () => "relay-preference",
      checkRateLimit: async () => ({ rateLimited: true }),
    }));
    expect(limited.status).toBe(429);
  });

  test("rejects unauthenticated callers", async () => {
    const response = await handleGetRelayPreference(getRequest(), deps({
      verifyRequest: async () => null,
    }));
    expect(response.status).toBe(401);
  });
});
