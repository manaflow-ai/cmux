import { afterEach, describe, expect, mock, test } from "bun:test";

const originalFetch = globalThis.fetch;
const originalEnv = {
  POSTHOG_ENVIRONMENT_ID: process.env.POSTHOG_ENVIRONMENT_ID,
  POSTHOG_PROJECT_ID: process.env.POSTHOG_PROJECT_ID,
  POSTHOG_PERSONAL_API_KEY: process.env.POSTHOG_PERSONAL_API_KEY,
};

const { assertPostHogDeletionConfigured, deletePostHogPersonData } = await import("../services/analytics/posthogDeletion");

afterEach(() => {
  globalThis.fetch = originalFetch;
  restoreEnv("POSTHOG_ENVIRONMENT_ID", originalEnv.POSTHOG_ENVIRONMENT_ID);
  restoreEnv("POSTHOG_PROJECT_ID", originalEnv.POSTHOG_PROJECT_ID);
  restoreEnv("POSTHOG_PERSONAL_API_KEY", originalEnv.POSTHOG_PERSONAL_API_KEY);
});

describe("PostHog account deletion", () => {
  test("posts bulk person deletion to the environment-scoped API", async () => {
    process.env.POSTHOG_ENVIRONMENT_ID = "env-123";
    delete process.env.POSTHOG_PROJECT_ID;
    process.env.POSTHOG_PERSONAL_API_KEY = "phx_personal";
    const requests: Array<{ url: string; init: RequestInit | undefined }> = [];
    globalThis.fetch = mock(async (...args: unknown[]) => {
      const [url, init] = args as [string | URL | Request, RequestInit | undefined];
      requests.push({ url: String(url), init });
      return new Response(null, { status: 200 });
    }) as unknown as typeof fetch;

    await deletePostHogPersonData("stack-user-1");

    expect(requests).toHaveLength(1);
    expect(requests[0].url).toBe("https://us.posthog.com/api/environments/env-123/persons/bulk_delete/");
    expect(requests[0].init?.method).toBe("POST");
    expect(requests[0].init?.headers).toEqual({
      "Authorization": "Bearer phx_personal",
      "Content-Type": "application/json",
    });
    expect(JSON.parse(String(requests[0].init?.body))).toEqual({
      distinct_ids: ["stack-user-1"],
      delete_events: true,
      delete_recordings: true,
    });
  });

  test("accepts legacy project id config as the PostHog environment id", () => {
    delete process.env.POSTHOG_ENVIRONMENT_ID;
    process.env.POSTHOG_PROJECT_ID = "legacy-project-id";
    process.env.POSTHOG_PERSONAL_API_KEY = "phx_personal";

    expect(() => assertPostHogDeletionConfigured()).not.toThrow();
  });
});

function restoreEnv(name: keyof typeof originalEnv, value: string | undefined): void {
  if (typeof value === "undefined") {
    delete process.env[name];
  } else {
    process.env[name] = value;
  }
}
