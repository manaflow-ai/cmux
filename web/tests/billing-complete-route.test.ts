import { beforeEach, describe, expect, mock, test } from "bun:test";
import { NextRequest } from "next/server";

import { makeBillingCompleteHandler } from "../app/api/billing/complete/route";

let stripeConfigured = true;
let retrievedSession: Record<string, unknown>;
const retrieveSession = mock(async () => retrievedSession);
const recordCheckoutCompletion = mock(async () => ({ stackUserId: "user-1", subscriptionId: "sub_1" }));

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
});
