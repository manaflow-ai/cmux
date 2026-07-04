import { afterEach, describe, expect, mock, test } from "bun:test";

const getDistinctId = mock(() => "posthog-distinct-id");
const getAnonymousId = mock(() => "anon-id");
const getGroups = mock(() => ({ organization: "org-1" }));
const getProperty = mock((key: unknown) => {
  switch (key) {
    case "$stored_person_properties":
      return { plan: "pro" };
    case "$stored_group_properties":
      return { organization: { tier: "team" } };
    case "anonymous_id":
      return "persisted-anon-id";
    case "$device_id":
      return "device-id";
    default:
      return undefined;
  }
});

mock.module("posthog-js", () => ({
  default: {
    get_distinct_id: getDistinctId,
    getAnonymousId,
    getGroups,
    get_property: getProperty,
    featureFlags: {
      $anon_distinct_id: "internal-anon-id",
    },
    config: {
      evaluation_contexts: ["web"],
    },
    persistence: {
      get_initial_props: () => ({
        plan: "free",
        initial_referrer: "https://example.com",
      }),
    },
  },
}));

const { getClientConfig, isClientConfigFlagEnabled } = await import("../app/lib/client-config");

const originalFetch = globalThis.fetch;

afterEach(() => {
  globalThis.fetch = originalFetch;
  getDistinctId.mockClear();
  getAnonymousId.mockClear();
  getGroups.mockClear();
  getProperty.mockClear();
});

describe("getClientConfig", () => {
  test("uses the PostHog distinct id by default", async () => {
    const fetchBodies: string[] = [];
    globalThis.fetch = mock(async (...args: unknown[]) => {
      const init = args[1] as RequestInit | undefined;
      if (typeof init?.body === "string") fetchBodies.push(init.body);
      return new Response(JSON.stringify({
        errorsWhileComputingFlags: false,
        featureFlags: {},
        featureFlagPayloads: {},
      }), { status: 200, headers: { "Content-Type": "application/json" } });
    }) as unknown as typeof fetch;

    await getClientConfig();

    expect(fetchBodies).toEqual([JSON.stringify({
      distinctId: "posthog-distinct-id",
      context: {
        groups: { organization: "org-1" },
        personProperties: {
          plan: "pro",
          initial_referrer: "https://example.com",
        },
        groupProperties: { organization: { tier: "team" } },
        anonDistinctId: "anon-id",
        deviceId: "device-id",
        timezone: Intl.DateTimeFormat().resolvedOptions().timeZone,
        evaluationContexts: ["web"],
      },
    })]);
  });

  test("allows callers to pass an explicit distinct id", async () => {
    const fetchBodies: string[] = [];
    globalThis.fetch = mock(async (...args: unknown[]) => {
      const init = args[1] as RequestInit | undefined;
      if (typeof init?.body === "string") fetchBodies.push(init.body);
      return new Response(JSON.stringify({
        errorsWhileComputingFlags: false,
        featureFlags: {},
        featureFlagPayloads: {},
      }), { status: 200, headers: { "Content-Type": "application/json" } });
    }) as unknown as typeof fetch;

    await getClientConfig({
      distinctId: "server-authoritative-id",
      context: { groups: { organization: "org-2" } },
    });

    expect(fetchBodies).toEqual([JSON.stringify({
      distinctId: "server-authoritative-id",
      context: { groups: { organization: "org-2" } },
    })]);
    expect(getDistinctId).not.toHaveBeenCalled();
    expect(getAnonymousId).not.toHaveBeenCalled();
    expect(getGroups).not.toHaveBeenCalled();
    expect(getProperty).not.toHaveBeenCalled();
  });

  test("normalizes first-party feature flag values", () => {
    expect(isClientConfigFlagEnabled(true, false)).toBe(true);
    expect(isClientConfigFlagEnabled(false, true)).toBe(false);
    expect(isClientConfigFlagEnabled("enabled", false)).toBe(true);
    expect(isClientConfigFlagEnabled("false", true)).toBe(false);
    expect(isClientConfigFlagEnabled("  ", true)).toBe(false);
    expect(isClientConfigFlagEnabled(undefined, true)).toBe(true);
  });
});
