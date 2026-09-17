import { beforeEach, describe, expect, mock, test } from "bun:test";
import { NextRequest } from "next/server";

import { makeBillingCompleteHandler } from "../app/api/billing/complete/route";

let stripeConfigured = true;
let retrievedSession: Record<string, unknown>;
const retrieveSession = mock(async () => retrievedSession);
let recordCheckoutCompletionResult: unknown = {
  stackUserId: "user-1",
  subscriptionId: "sub_1",
};
const recordCheckoutCompletion = mock(async () => recordCheckoutCompletionResult);
const recordFoundersCheckoutCompletion = mock(async () => ({
  scope: "user" as const,
  stackUserId: "founder-user",
  subscriptionId: "founder-subscription",
}));

const GET = makeBillingCompleteHandler({
  isConfigured: () => stripeConfigured,
  stripe: () =>
    ({
      checkout: {
        sessions: {
          retrieve: retrieveSession,
        },
      },
    }) as never,
  recordCheckoutCompletion: recordCheckoutCompletion as never,
  recordFoundersCheckoutCompletion: recordFoundersCheckoutCompletion as never,
});

describe("billing complete route", () => {
  beforeEach(() => {
    stripeConfigured = true;
    retrievedSession = {
      id: "cs_123",
      payment_status: "paid",
      client_reference_id: "user-1",
      metadata: { app: "cmux", plan: "pro" },
      subscription: { id: "sub_1" },
      customer: { id: "cus_1" },
    };
    retrieveSession.mockClear();
    recordCheckoutCompletion.mockClear();
    recordFoundersCheckoutCompletion.mockClear();
    recordCheckoutCompletionResult = {
      stackUserId: "user-1",
      subscriptionId: "sub_1",
    };
  });

  test("records paid sessions and redirects to success with the validated scheme", async () => {
    process.env.CMUX_DEV_NATIVE_CALLBACK_SCHEMES = "cmux-dev-local";
    const response = await GET(
      new NextRequest(
        "http://localhost:3777/api/billing/complete?session_id=cs_123&cmux_scheme=cmux-dev-local",
      ),
    );

    expect(retrieveSession).toHaveBeenCalledWith("cs_123", {
      expand: ["subscription", "customer"],
    });
    expect(recordCheckoutCompletion).toHaveBeenCalledWith({
      session: retrievedSession,
      subscription: retrievedSession.subscription,
      customer: retrievedSession.customer,
    });
    expect(response.status).toBe(307);
    expect(response.headers.get("location")).toBe(
      "http://localhost:3777/billing/success?session_id=cs_123&cmux_scheme=cmux-dev-local",
    );
  });

  test("uses the callback scheme trusted at checkout on a deployed completion host", async () => {
    retrievedSession = {
      id: "cs_123",
      payment_status: "paid",
      client_reference_id: "user-1",
      metadata: {
        app: "cmux",
        plan: "pro",
        nativeCallbackScheme: "cmux-dev-local",
      },
      subscription: { id: "sub_1" },
      customer: { id: "cus_1" },
    };
    const response = await GET(
      new NextRequest(
        "https://cmux.test/api/billing/complete?session_id=cs_123&cmux_scheme=cmux-dev-local",
      ),
    );

    expect(response.headers.get("location")).toBe(
      "https://cmux.test/billing/success?session_id=cs_123&cmux_scheme=cmux-dev-local",
    );
  });

  test("redirects unpaid sessions to pending pricing state", async () => {
    retrievedSession = {
      id: "cs_123",
      payment_status: "unpaid",
      client_reference_id: "user-1",
      metadata: { app: "cmux", plan: "pro" },
    };

    const response = await GET(
      new NextRequest("https://cmux.test/api/billing/complete?session_id=cs_123"),
    );

    expect(recordCheckoutCompletion).not.toHaveBeenCalled();
    expect(response.headers.get("location")).toBe("https://cmux.test/pricing?welcome=pending");
  });

  test("redirects paid Team sessions to dashboard billing after recording", async () => {
    retrievedSession = {
      id: "cs_team",
      payment_status: "paid",
      client_reference_id: "team-1",
      metadata: { app: "cmux", plan: "team", stackTeamId: "team-1" },
      subscription: { id: "sub_team" },
      customer: { id: "cus_team" },
    };

    const response = await GET(
      new NextRequest("https://cmux.test/api/billing/complete?session_id=cs_team"),
    );

    expect(recordCheckoutCompletion).toHaveBeenCalled();
    expect(response.status).toBe(307);
    expect(response.headers.get("location")).toBe(
      "https://cmux.test/dashboard/billing?welcome=team",
    );
  });

  test("records paid Founder sessions through the Founder completion path", async () => {
    retrievedSession = {
      id: "cs_founder",
      payment_status: "paid",
      client_reference_id: null,
      metadata: { founders_edition: "true" },
      subscription: null,
      customer: { id: "cus_founder" },
    };

    const response = await GET(
      new NextRequest("https://cmux.test/api/billing/complete?session_id=cs_founder"),
    );

    expect(recordFoundersCheckoutCompletion).toHaveBeenCalledWith({
      session: retrievedSession,
      subscription: null,
      customer: retrievedSession.customer,
    });
    expect(recordCheckoutCompletion).not.toHaveBeenCalled();
    expect(response.headers.get("location")).toBe(
      "https://cmux.test/billing/success?session_id=cs_founder&cmux_scheme=cmux",
    );
  });

  test("rejects conflicting Team and Founder metadata before provisioning", async () => {
    retrievedSession = {
      id: "cs_conflicting_scope",
      payment_status: "paid",
      client_reference_id: "team-1",
      metadata: {
        founders_edition: "true",
        app: "cmux",
        plan: "team",
        stackTeamId: "team-1",
      },
      subscription: {
        id: "sub_conflicting_scope",
        metadata: {
          founders_edition: "true",
          app: "cmux",
          plan: "team",
          stackTeamId: "team-1",
        },
      },
      customer: { id: "cus_conflicting_scope" },
    };

    const response = await GET(
      new NextRequest(
        "https://cmux.test/api/billing/complete?session_id=cs_conflicting_scope",
      ),
    );

    expect(recordFoundersCheckoutCompletion).not.toHaveBeenCalled();
    expect(recordCheckoutCompletion).not.toHaveBeenCalled();
    expect(response.headers.get("location")).toBe(
      "https://cmux.test/pricing?billing=error",
    );
  });

  test("does not redirect to success when checkout is cancelled for account deletion", async () => {
    recordCheckoutCompletionResult = {
      skipped: "account_deletion_in_progress",
      stackUserId: "user-1",
      subscriptionId: "sub_1",
    };

    const response = await GET(
      new NextRequest("https://cmux.test/api/billing/complete?session_id=cs_123"),
    );

    expect(recordCheckoutCompletion).toHaveBeenCalled();
    expect(response.status).toBe(307);
    expect(response.headers.get("location")).toBe(
      "https://cmux.test/pricing?billing=account_deletion",
    );
  });

  test("rejects foreign paid sessions without recording them", async () => {
    retrievedSession = {
      id: "cs_foreign",
      payment_status: "paid",
      client_reference_id: "foreign-user",
      metadata: { app: "other", plan: "pro" },
    };

    const response = await GET(
      new NextRequest("https://cmux.test/api/billing/complete?session_id=cs_foreign"),
    );

    expect(recordCheckoutCompletion).not.toHaveBeenCalled();
    expect(response.headers.get("location")).toBe("https://cmux.test/pricing?billing=error");
  });

  test("rejects a foreign session when its expanded subscription says Founder", async () => {
    retrievedSession = {
      id: "cs_foreign_founder",
      payment_status: "paid",
      client_reference_id: "foreign-user",
      metadata: { app: "other", plan: "pro" },
      subscription: {
        id: "sub_foreign_founder",
        metadata: { app: "cmux", founders_edition: "true" },
      },
      customer: { id: "cus_foreign_founder" },
    };

    const response = await GET(
      new NextRequest(
        "https://cmux.test/api/billing/complete?session_id=cs_foreign_founder",
      ),
    );

    expect(recordFoundersCheckoutCompletion).not.toHaveBeenCalled();
    expect(recordCheckoutCompletion).not.toHaveBeenCalled();
    expect(response.headers.get("location")).toBe("https://cmux.test/pricing?billing=error");
  });
});
