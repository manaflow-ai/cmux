import { afterAll, afterEach, describe, expect, test } from "bun:test";

const ENV_KEYS = [
  "SKIP_ENV_VALIDATION",
  "NEXT_PUBLIC_STACK_PROJECT_ID",
  "NEXT_PUBLIC_STACK_PUBLISHABLE_CLIENT_KEY",
  "STACK_SECRET_SERVER_KEY",
  "STACK_API_BASE_URL",
] as const;
const savedEnv = Object.fromEntries(ENV_KEYS.map((key) => [key, process.env[key]]));
Object.assign(process.env, {
  SKIP_ENV_VALIDATION: "1",
  NEXT_PUBLIC_STACK_PROJECT_ID: "00000000-0000-4000-8000-0000000000aa",
  NEXT_PUBLIC_STACK_PUBLISHABLE_CLIENT_KEY: "pck_test",
  STACK_SECRET_SERVER_KEY: "ssk_test",
  STACK_API_BASE_URL: "https://stack.test",
});
afterAll(() => {
  for (const key of ENV_KEYS) {
    if (savedEnv[key] === undefined) delete process.env[key];
    else process.env[key] = savedEnv[key];
  }
});

const { defaultTeamStackApp } = await import("../services/teams/stack");
const { listReceivedInvitations } = await import("../services/teams/received");
const { TeamApiError, TeamServiceUnavailableError } = await import("../services/teams/errors");
const { isStackThrottleFetchGuardInstalled } = await import("../services/auth/stackThrottleFetchGuard");

const originalFetch = globalThis.fetch;
const USER = "00000000-0000-4000-8000-0000000000bb";

type Seen = { url: URL; headers: Headers };

function stubFetch(seen: Seen[], response: () => Response): void {
  globalThis.fetch = (async (input: RequestInfo | URL, init?: RequestInit) => {
    seen.push({ url: new URL(input instanceof Request ? input.url : String(input)), headers: new Headers(init?.headers) });
    return response();
  }) as typeof fetch;
}

const emptyStore = {
  listPendingEmailInvitationsForEmails: async () => [],
} as unknown as NonNullable<Parameters<typeof listReceivedInvitations>[1]>["store"];

afterEach(() => {
  globalThis.fetch = originalFetch;
});

describe("contact-channel read", () => {
  test("asks Stack's server API for the user's channels and keeps only the verified flag it reports", async () => {
    const seen: Seen[] = [];
    stubFetch(seen, () => Response.json({
      items: [
        { id: "c1", user_id: USER, type: "email", value: "a@example.com", is_verified: true, is_primary: true },
        { id: "c2", user_id: USER, type: "email", value: "b@example.com", is_verified: false, is_primary: false },
        { id: "c3", user_id: USER, type: "email", value: "c@example.com", is_primary: false },
      ],
    }));
    const channels = await defaultTeamStackApp().listUserContactChannels(USER);
    expect(channels).toEqual([
      { type: "email", value: "a@example.com", isVerified: true },
      { type: "email", value: "b@example.com", isVerified: false },
      { type: "email", value: "c@example.com", isVerified: false },
    ]);
    expect(seen).toHaveLength(1);
    expect(`${seen[0]!.url.origin}${seen[0]!.url.pathname}`).toBe("https://stack.test/api/v1/contact-channels");
    expect(seen[0]!.url.searchParams.get("user_id")).toBe(USER);
    expect(seen[0]!.headers.get("x-hexclave-access-type")).toBe("server");
    expect(seen[0]!.headers.get("x-hexclave-project-id")).toBe(process.env.NEXT_PUBLIC_STACK_PROJECT_ID!);
  });

  test("a Stack 429 surfaces as a retryable team-service outage", async () => {
    stubFetch([], () => new Response("{}", { status: 429, headers: { "retry-after": "5" } }));
    await expect(listReceivedInvitations(USER, { store: emptyStore })).rejects.toBeInstanceOf(TeamServiceUnavailableError);
  });

  test("a user Stack does not know is unauthorized, not an outage", async () => {
    stubFetch([], () => new Response(JSON.stringify({ code: "USER_NOT_FOUND" }), {
      status: 404,
      headers: { "x-hexclave-known-error": "USER_NOT_FOUND" },
    }));
    const failure = await listReceivedInvitations(USER, { store: emptyStore }).catch((error: unknown) => error);
    expect(failure).toBeInstanceOf(TeamApiError);
    expect(failure).toMatchObject({ code: "unauthorized", status: 401 });
  });
});

describe("instrumentation", () => {
  test("register installs the Stack throttle guard in the Node runtime", async () => {
    const previousRuntime = process.env.NEXT_RUNTIME;
    process.env.NEXT_RUNTIME = "nodejs";
    try {
      expect(isStackThrottleFetchGuardInstalled(globalThis)).toBe(false);
      const { register } = await import("../instrumentation");
      await register();
      expect(isStackThrottleFetchGuardInstalled(globalThis)).toBe(true);
    } finally {
      if (previousRuntime === undefined) delete process.env.NEXT_RUNTIME;
      else process.env.NEXT_RUNTIME = previousRuntime;
    }
  });
});
