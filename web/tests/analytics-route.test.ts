import { afterEach, beforeEach, describe, expect, mock, test } from "bun:test";
import type { AuthedUser } from "../services/vms/auth";

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

const verifyRequest = mock(async (): Promise<AuthedUser | null> => authedUser);
const recordIOSAnalyticsIdentities = mock(async () => {});
const forwardToPostHog = mock(async () => ({ ok: true as const }));

const { postAnalyticsEvents } = await import("../app/api/analytics/events/route");

beforeEach(() => {
  verifyRequest.mockClear();
  verifyRequest.mockResolvedValue(authedUser);
  recordIOSAnalyticsIdentities.mockClear();
  forwardToPostHog.mockClear();
  forwardToPostHog.mockResolvedValue({ ok: true });
});

afterEach(() => {
  forwardToPostHog.mockResolvedValue({ ok: true });
});

describe("iOS analytics route", () => {
  test("persists authenticated mobile anonymous ids before forwarding", async () => {
    const response = await postAnalyticsEvents(jsonRequest({
      batch: [{
        event: "$identify",
        distinct_id: "stack-user-1",
        properties: {
          client_id: "anon-client-1",
          "$anon_distinct_id": "anon-client-1",
        },
      }],
    }), dependencies());

    expect(response.status).toBe(200);
    expect(recordIOSAnalyticsIdentities).toHaveBeenCalledWith({
      userId: "stack-user-1",
      anonymousIds: ["anon-client-1", "anon-client-1"],
    });
    expect(forwardToPostHog).toHaveBeenCalled();
  });

  test("keeps the deletion mapping even when PostHog forwarding fails", async () => {
    forwardToPostHog.mockResolvedValue({ ok: false, status: 502 });

    const response = await postAnalyticsEvents(jsonRequest({
      batch: [{
        event: "ios_app_foregrounded",
        distinct_id: "stack-user-1",
        properties: {
          client_id: "anon-client-2",
        },
      }],
    }), dependencies());

    expect(response.status).toBe(502);
    expect(recordIOSAnalyticsIdentities).toHaveBeenCalledWith({
      userId: "stack-user-1",
      anonymousIds: ["anon-client-2"],
    });
  });

  test("does not persist anonymous-only analytics ids without a Stack user", async () => {
    verifyRequest.mockResolvedValue(null);

    const response = await postAnalyticsEvents(jsonRequest({
      batch: [{
        event: "ios_app_first_launch",
        distinct_id: "anon-client-3",
        properties: {
          client_id: "anon-client-3",
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
    recordIOSAnalyticsIdentities,
    forwardToPostHog,
  };
}

function jsonRequest(body: unknown): Request {
  return new Request("https://cmux.com/api/analytics/events", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(body),
  });
}
