import { afterEach, beforeEach, describe, expect, mock, test } from "bun:test";
import type { AuthedUser } from "../services/vms/auth";

process.env.RESEND_API_KEY ??= "test-resend-key";
process.env.CMUX_FEEDBACK_FROM_EMAIL ??= "feedback@example.com";
process.env.CMUX_FEEDBACK_RATE_LIMIT_ID ??= "test-feedback-rate-limit";
process.env.STACK_SECRET_SERVER_KEY ??= "test-stack-secret";
process.env.NEXT_PUBLIC_STACK_PROJECT_ID ??= "00000000-0000-4000-8000-000000000000";
process.env.NEXT_PUBLIC_STACK_PUBLISHABLE_CLIENT_KEY ??= "test-stack-publishable";

const authedUser: AuthedUser = {
  id: "stack-user-1",
  displayName: null,
  primaryEmail: null,
  billingCustomerType: "user",
  billingTeamId: "stack-user-1",
  selectedTeamId: null,
  teams: [],
  teamIds: [],
  userBillingPlanId: null,
  billingPlanId: null,
};
type RecordIOSAnalyticsIdentities = typeof import(
  "../services/analytics/iosAnalyticsIdentities"
).recordIOSAnalyticsIdentities;

const verifyRequest = mock(async (): Promise<AuthedUser | null> => authedUser);
const recordIOSAnalyticsIdentities = mock(async (...args: unknown[]) => {
  const [input] = args as Parameters<RecordIOSAnalyticsIdentities>;
  return input.anonymousIds;
});
const forwardToPostHog = mock(async () => ({ ok: true as const }));
const deletePostHogPersonData = mock(async () => undefined);
async function runAuthenticatedAnalytics<T>(
  _userId: string,
  run: (db: never) => Promise<T>,
): Promise<T> {
  return await run({} as never);
}

const {
  AnalyticsAccountDeletionBlockedError,
  postAnalyticsEvents,
} = await import("../app/api/analytics/events/route");

beforeEach(() => {
  verifyRequest.mockClear();
  verifyRequest.mockResolvedValue(authedUser);
  recordIOSAnalyticsIdentities.mockClear();
  forwardToPostHog.mockClear();
  forwardToPostHog.mockResolvedValue({ ok: true });
  deletePostHogPersonData.mockClear();
});

afterEach(() => {
  forwardToPostHog.mockResolvedValue({ ok: true });
});

describe("iOS analytics route", () => {
  test("persists authenticated mobile anonymous ids after an accepted identify", async () => {
    const response = await postAnalyticsEvents(jsonRequest({
      batch: [{
        event: "$identify",
        distinct_id: "stack-user-1",
        properties: {
          "$anon_distinct_id": "11111111-1111-4111-8111-111111111111",
        },
      }],
    }), dependencies());

    expect(response.status).toBe(200);
    expect(recordIOSAnalyticsIdentities).toHaveBeenCalledWith({
      userId: "stack-user-1",
      anonymousIds: ["11111111-1111-4111-8111-111111111111"],
    });
    expect(forwardToPostHog).toHaveBeenCalled();
  });

  test("strips authenticated identify aliases when the client distinct id is stale", async () => {
    let forwardedProperties: Record<string, unknown> | null = null;
    const response = await postAnalyticsEvents(jsonRequest({
      batch: [{
        event: "$identify",
        distinct_id: "stale-install-id",
        properties: {
          "$anon_distinct_id": "55555555-5555-4555-8555-555555555555",
        },
      }],
    }), {
      ...dependencies(),
      forwardToPostHog: async (events: readonly { readonly properties: Record<string, unknown> }[]) => {
        forwardedProperties = events[0]?.properties ?? null;
        return { ok: true };
      },
    });

    expect(response.status).toBe(200);
    expect(recordIOSAnalyticsIdentities).not.toHaveBeenCalled();
    expect(forwardedProperties).toEqual({});
  });

  test("strips authenticated capture-event anonymous aliases before forwarding", async () => {
    let forwardedProperties: Record<string, unknown> | null = null;
    const response = await postAnalyticsEvents(jsonRequest({
      batch: [{
        event: "ios_app_foregrounded",
        distinct_id: "stack-user-1",
        properties: {
          "$anon_distinct_id": "66666666-6666-4666-8666-666666666666",
          client_id: "66666666-6666-4666-8666-666666666666",
        },
      }],
    }), {
      ...dependencies(),
      forwardToPostHog: async (events: readonly { readonly properties: Record<string, unknown> }[]) => {
        forwardedProperties = events[0]?.properties ?? null;
        return { ok: true };
      },
    });

    expect(response.status).toBe(200);
    expect(recordIOSAnalyticsIdentities).not.toHaveBeenCalled();
    expect(forwardedProperties).toEqual({
      client_id: "66666666-6666-4666-8666-666666666666",
    });
  });

  test("drops unapproved properties from allowed analytics events", async () => {
    let forwardedProperties: Record<string, unknown> | null = null;
    const response = await postAnalyticsEvents(jsonRequest({
      batch: [{
        event: "ios_terminal_input_submitted",
        distinct_id: "stack-user-1",
        properties: {
          client_id: "66666666-6666-4666-8666-666666666666",
          byte_count: 42,
          line_count: 2,
          had_attachment: false,
          terminal_text: "cat ~/.ssh/id_rsa",
          auth_token: "secret-token",
          prompt: "ship it",
        },
      }],
    }), {
      ...dependencies(),
      forwardToPostHog: async (events: readonly { readonly properties: Record<string, unknown> }[]) => {
        forwardedProperties = events[0]?.properties ?? null;
        return { ok: true };
      },
    });

    expect(response.status).toBe(200);
    expect(forwardedProperties).toEqual({
      client_id: "66666666-6666-4666-8666-666666666666",
      byte_count: 42,
      line_count: 2,
      had_attachment: false,
    });
  });

  test("strips authenticated identify aliases that are not durably recorded", async () => {
    let forwardedProperties: Record<string, unknown> | null = null;
    const response = await postAnalyticsEvents(jsonRequest({
      batch: [{
        event: "$identify",
        distinct_id: "stack-user-1",
        properties: {
          "$anon_distinct_id": "not-a-valid-install-id",
        },
      }],
    }), {
      ...dependencies(),
      recordIOSAnalyticsIdentities: async () => [],
      forwardToPostHog: async (events: readonly { readonly properties: Record<string, unknown> }[]) => {
        forwardedProperties = events[0]?.properties ?? null;
        return { ok: true };
      },
    });

    expect(response.status).toBe(200);
    expect(forwardedProperties).toEqual({});
  });

  test("records identify mappings before forwarding to PostHog", async () => {
    const calls: string[] = [];

    const response = await postAnalyticsEvents(jsonRequest({
      batch: [{
        event: "$identify",
        distinct_id: "stack-user-1",
        properties: {
          "$anon_distinct_id": "22222222-2222-4222-8222-222222222222",
        },
      }],
    }), {
      ...dependencies(),
      recordIOSAnalyticsIdentities: async (input) => {
        calls.push("record-identities");
        return input.anonymousIds;
      },
      forwardToPostHog: async () => {
        calls.push("forward-posthog");
        return { ok: true };
      },
      runAuthenticatedAnalytics: async (userId, run) => {
        calls.push(`deletion-lock:${userId}`);
        const response = await run({} as never);
        calls.push("deletion-unlock");
        return response;
      },
    });

    expect(response.status).toBe(200);
    expect(calls).toEqual([
      "deletion-lock:stack-user-1",
      "record-identities",
      "deletion-unlock",
      "deletion-lock:stack-user-1",
      "deletion-unlock",
      "forward-posthog",
      "deletion-lock:stack-user-1",
      "deletion-unlock",
    ]);
  });

  test("does not forward when account deletion starts after identity recording commits", async () => {
    let lockCount = 0;

    const response = await postAnalyticsEvents(jsonRequest({
      batch: [{
        event: "$identify",
        distinct_id: "stack-user-1",
        properties: {
          "$anon_distinct_id": "99999999-9999-4999-8999-999999999999",
        },
      }],
    }), {
      ...dependencies(),
      runAuthenticatedAnalytics: async (_userId, run) => {
        lockCount += 1;
        if (lockCount === 2) throw new AnalyticsAccountDeletionBlockedError();
        return await run({} as never);
      },
    });

    expect(response.status).toBe(200);
    expect(await response.json()).toEqual({ ok: true, forwarded: 0 });
    expect(recordIOSAnalyticsIdentities).toHaveBeenCalledWith({
      userId: "stack-user-1",
      anonymousIds: ["99999999-9999-4999-8999-999999999999"],
    });
    expect(forwardToPostHog).not.toHaveBeenCalled();
  });

  test("deletes PostHog data when account deletion starts during forwarding", async () => {
    let lockCount = 0;

    const response = await postAnalyticsEvents(jsonRequest({
      batch: [{
        event: "$identify",
        distinct_id: "stack-user-1",
        properties: {
          "$anon_distinct_id": "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
        },
      }],
    }), {
      ...dependencies(),
      runAuthenticatedAnalytics: async (_userId, run) => {
        lockCount += 1;
        if (lockCount === 3) throw new AnalyticsAccountDeletionBlockedError();
        return await run({} as never);
      },
    });

    expect(response.status).toBe(200);
    expect(await response.json()).toEqual({ ok: true, forwarded: 0 });
    expect(forwardToPostHog).toHaveBeenCalled();
    expect(deletePostHogPersonData).toHaveBeenCalledWith(
      "stack-user-1",
      ["stack-user-1", "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"],
    );
  });

  test("does not forward authenticated analytics after account deletion starts", async () => {
    const response = await postAnalyticsEvents(jsonRequest({
      batch: [{
        event: "$identify",
        distinct_id: "stack-user-1",
        properties: {
          "$anon_distinct_id": "88888888-8888-4888-8888-888888888888",
        },
      }],
    }), {
      ...dependencies(),
      runAuthenticatedAnalytics: async () => {
        throw new AnalyticsAccountDeletionBlockedError();
      },
    });

    expect(response.status).toBe(200);
    expect(await response.json()).toEqual({ ok: true, forwarded: 0 });
    expect(recordIOSAnalyticsIdentities).not.toHaveBeenCalled();
    expect(forwardToPostHog).not.toHaveBeenCalled();
  });

  test("does not forward analytics when identity recording fails", async () => {
    const originalConsoleError = console.error;
    const consoleError = mock(() => {});
    const identityStoreError = new Error("identity store unavailable");
    console.error = consoleError as unknown as typeof console.error;

    try {
      const response = await postAnalyticsEvents(jsonRequest({
        batch: [{
          event: "$identify",
          distinct_id: "stack-user-1",
          properties: {
            "$anon_distinct_id": "77777777-7777-4777-8777-777777777777",
          },
        }],
      }), {
        ...dependencies(),
        recordIOSAnalyticsIdentities: async () => {
          throw identityStoreError;
        },
        forwardToPostHog,
      });

      expect(response.status).toBe(503);
      expect(await response.json()).toEqual({ error: "identity_recording_failed" });
      expect(forwardToPostHog).not.toHaveBeenCalled();
      expect(consoleError).toHaveBeenCalledWith(
        "[ios-analytics] identity recording failed",
        { error: identityStoreError },
      );
    } finally {
      console.error = originalConsoleError;
    }
  });

  test("keeps identify mappings when PostHog forwarding fails", async () => {
    forwardToPostHog.mockResolvedValue({ ok: false, status: 502 });

    const response = await postAnalyticsEvents(jsonRequest({
      batch: [{
        event: "$identify",
        distinct_id: "stack-user-1",
        properties: {
          "$anon_distinct_id": "22222222-2222-4222-8222-222222222222",
        },
      }],
    }), dependencies());

    expect(response.status).toBe(502);
    expect(recordIOSAnalyticsIdentities).toHaveBeenCalledWith({
      userId: "stack-user-1",
      anonymousIds: ["22222222-2222-4222-8222-222222222222"],
    });
  });

  test("does not persist anonymous-only analytics ids without a Stack user", async () => {
    verifyRequest.mockResolvedValue(null);

    const response = await postAnalyticsEvents(jsonRequest({
      batch: [{
        event: "ios_app_first_launch",
        distinct_id: "33333333-3333-4333-8333-333333333333",
        properties: {
          client_id: "33333333-3333-4333-8333-333333333333",
        },
      }],
    }), dependencies());

    expect(response.status).toBe(200);
    expect(recordIOSAnalyticsIdentities).not.toHaveBeenCalled();
  });

  test("drops anonymous identify aliases before forwarding", async () => {
    verifyRequest.mockResolvedValue(null);

    const response = await postAnalyticsEvents(jsonRequest({
      batch: [{
        event: "$identify",
        distinct_id: "33333333-3333-4333-8333-333333333333",
        properties: {
          "$anon_distinct_id": "44444444-4444-4444-8444-444444444444",
        },
      }],
    }), dependencies());

    expect(response.status).toBe(200);
    expect(await response.json()).toEqual({ ok: true, forwarded: 0 });
    expect(recordIOSAnalyticsIdentities).not.toHaveBeenCalled();
    expect(forwardToPostHog).not.toHaveBeenCalled();
  });

  test("does not persist capture-event client ids as deletion identities", async () => {
    const response = await postAnalyticsEvents(jsonRequest({
      batch: [{
        event: "ios_app_foregrounded",
        distinct_id: "stack-user-1",
        properties: {
          client_id: "44444444-4444-4444-8444-444444444444",
        },
      }],
    }), dependencies());

    expect(response.status).toBe(200);
    expect(recordIOSAnalyticsIdentities).not.toHaveBeenCalled();
  });
});

function dependencies() {
  return {
    verifyRequest,
    recordIOSAnalyticsIdentities: async (input: Parameters<RecordIOSAnalyticsIdentities>[0]) =>
      await recordIOSAnalyticsIdentities(input),
    forwardToPostHog,
    deletePostHogPersonData,
    runAuthenticatedAnalytics,
  };
}

function jsonRequest(body: unknown): Request {
  return new Request("https://cmux.com/api/analytics/events", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(body),
  });
}
