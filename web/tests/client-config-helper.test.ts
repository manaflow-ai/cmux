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

const { getClientConfig } = await import("../app/lib/client-config");

const originalFetch = globalThis.fetch;
const originalWindow = globalThis.window;

afterEach(() => {
  globalThis.fetch = originalFetch;
  restoreWindow(originalWindow);
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

  test("reuses a successful response from browser storage for five minutes", async () => {
    const storage = installStorage();
    const fetchMock = mock(async () => new Response(JSON.stringify({
      errorsWhileComputingFlags: false,
      featureFlags: { "pricing-page-visible": true },
      featureFlagPayloads: {},
    }), { status: 200, headers: { "Content-Type": "application/json" } }));
    globalThis.fetch = fetchMock as unknown as typeof fetch;

    const first = await getClientConfig({ distinctId: "cache-id", context: {} });
    const second = await getClientConfig({ distinctId: "cache-id", context: {} });

    expect(second).toEqual(first);
    expect(fetchMock).toHaveBeenCalledTimes(1);
    const stored = JSON.parse(storage.getItem("cmux.client-config.v1") ?? "null") as {
      requestBody: string;
      expiresAt: unknown;
      config: unknown;
    };
    expect(stored).toMatchObject({
      requestBody: JSON.stringify({ distinctId: "cache-id", context: {} }),
      config: first,
    });
    expect(typeof stored.expiresAt).toBe("number");

    // A full-navigation-style memory miss can hydrate from localStorage.
    const persisted = storage.getItem("cmux.client-config.v1");
    await getClientConfig({ distinctId: "other-cache-id", context: {} });
    storage.setItem("cmux.client-config.v1", persisted ?? "");
    expect(await getClientConfig({ distinctId: "cache-id", context: {} })).toEqual(first);
    expect(fetchMock).toHaveBeenCalledTimes(2);
  });

  test("deduplicates concurrent requests for the same evaluation", async () => {
    let resolveResponse: ((response: Response) => void) | undefined;
    const response = new Promise<Response>((resolve) => {
      resolveResponse = resolve;
    });
    const fetchMock = mock(() => response);
    globalThis.fetch = fetchMock as unknown as typeof fetch;

    const first = getClientConfig({ distinctId: "in-flight-id", context: {} });
    const second = getClientConfig({ distinctId: "in-flight-id", context: {} });
    expect(fetchMock).toHaveBeenCalledTimes(1);

    resolveResponse?.(new Response(JSON.stringify({
      errorsWhileComputingFlags: false,
      featureFlags: {},
      featureFlagPayloads: {},
    }), { status: 200, headers: { "Content-Type": "application/json" } }));
    await expect(Promise.all([first, second])).resolves.toHaveLength(2);
  });

  test("does not reuse cached flags after identity or context changes", async () => {
    installStorage();
    const fetchMock = mock(async () => new Response(JSON.stringify({
      errorsWhileComputingFlags: false,
      featureFlags: {},
      featureFlagPayloads: {},
    }), { status: 200, headers: { "Content-Type": "application/json" } }));
    globalThis.fetch = fetchMock as unknown as typeof fetch;

    await getClientConfig({ distinctId: "first-user", context: {} });
    await getClientConfig({ distinctId: "second-user", context: {} });
    await getClientConfig({ distinctId: "second-user", context: { groups: { organization: "org-2" } } });

    expect(fetchMock).toHaveBeenCalledTimes(3);
  });

  test("does not persist partial flag evaluations", async () => {
    const storage = installStorage();
    const fetchMock = mock(async () => new Response(JSON.stringify({
      errorsWhileComputingFlags: true,
      featureFlags: {},
      featureFlagPayloads: {},
    }), { status: 200, headers: { "Content-Type": "application/json" } }));
    globalThis.fetch = fetchMock as unknown as typeof fetch;

    await getClientConfig({ distinctId: "partial-evaluation", context: {} });
    await getClientConfig({ distinctId: "partial-evaluation", context: {} });

    expect(fetchMock).toHaveBeenCalledTimes(2);
    expect(storage.getItem("cmux.client-config.v1")).toBeNull();
  });

  test("refetches after the five-minute cache expires", async () => {
    const storage = installStorage();
    const originalNow = Date.now;
    let now = 1_000;
    Date.now = () => now;
    const fetchMock = mock(async () => new Response(JSON.stringify({
      errorsWhileComputingFlags: false,
      featureFlags: {},
      featureFlagPayloads: {},
    }), { status: 200, headers: { "Content-Type": "application/json" } }));
    globalThis.fetch = fetchMock as unknown as typeof fetch;

    try {
      await getClientConfig({ distinctId: "expiring-cache-id", context: {} });
      expect(storage.getItem("cmux.client-config.v1")).not.toBeNull();

      now += 5 * 60 * 1000 + 1;
      await getClientConfig({ distinctId: "expiring-cache-id", context: {} });
    } finally {
      Date.now = originalNow;
    }

    expect(fetchMock).toHaveBeenCalledTimes(2);
  });
});

function installStorage(): Storage {
  const values = new Map<string, string>();
  const storage = {
    getItem: (key: string) => values.get(key) ?? null,
    setItem: (key: string, value: string) => values.set(key, value),
    removeItem: (key: string) => values.delete(key),
    clear: () => values.clear(),
    key: (index: number) => [...values.keys()][index] ?? null,
    get length() {
      return values.size;
    },
  } as Storage;
  Object.defineProperty(globalThis, "window", {
    configurable: true,
    value: { localStorage: storage },
  });
  return storage;
}

function restoreWindow(value: typeof globalThis.window): void {
  if (typeof value === "undefined") {
    delete (globalThis as { window?: typeof globalThis.window }).window;
  } else {
    Object.defineProperty(globalThis, "window", {
      configurable: true,
      value,
    });
  }
}
