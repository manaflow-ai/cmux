import { afterAll, beforeEach, describe, expect, mock, test } from "bun:test";

const originalFetch = globalThis.fetch;

const resendSend = mock(async () => ({ data: { id: "email_1" }, error: null }));
const resendCtor = mock((apiKey: unknown) => apiKey);
const fetchMock = mock(async () => new Response("ok", { status: 200 }));

globalThis.fetch = fetchMock as unknown as typeof fetch;

function dnsError(code: string): NodeJS.ErrnoException {
  const err = new Error(code) as NodeJS.ErrnoException;
  err.code = code;
  return err;
}

mock.module("node:dns", () => ({
  promises: {
    resolveMx: async (domain: string) => {
      if (domain === "good.test") {
        return [{ exchange: "mx.good.test", priority: 10 }];
      }
      throw dnsError("ENOTFOUND");
    },
    resolve4: async () => {
      throw dnsError("ENOTFOUND");
    },
    resolve6: async () => {
      throw dnsError("ENOTFOUND");
    },
  },
}));

mock.module("@/app/env", () => ({
  env: {
    RESEND_API_KEY: "re_test",
    CMUX_FEEDBACK_FROM_EMAIL: "founders@manaflow.com",
    CMUX_FEEDBACK_RATE_LIMIT_ID: "enterprise-test",
    STACK_SECRET_SERVER_KEY: "stack-secret",
    SLACK_ENTERPRISE_WEBHOOK_URL: "https://slack.test/enterprise",
    SLACK_WAITLIST_WEBHOOK_URL: undefined,
  },
}));

mock.module("resend", () => ({
  Resend: class MockResend {
    emails = { send: resendSend };

    constructor(apiKey: string) {
      resendCtor(apiKey);
    }
  },
}));

const { POST } = await import("../app/api/enterprise/contact/route");

afterAll(() => {
  globalThis.fetch = originalFetch;
});

beforeEach(() => {
  resendSend.mockClear();
  resendCtor.mockClear();
  fetchMock.mockClear();
  fetchMock.mockResolvedValue(new Response("ok", { status: 200 }));
});

function request(body: unknown): Request {
  return new Request("https://cmux.test/api/enterprise/contact", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(body),
  });
}

function validLead(overrides: Record<string, unknown> = {}) {
  return {
    firstName: "Ada",
    lastName: "Lovelace",
    companyName: "Analytical Engines Inc.",
    jobFunction: "Engineering",
    jobTitle: "CTO",
    businessEmail: "ada@good.test",
    phoneNumber: "+1 555 0100",
    country: "United States",
    companySize: "51-200",
    deploymentNeeds: "SSO or SAML",
    comments: "Need audit logs and self-hosted Cloud VMs.",
    ...overrides,
  };
}

describe("enterprise contact route", () => {
  test("rejects malformed submissions", async () => {
    const response = await POST(request({ firstName: "Ada" }));

    expect(response.status).toBe(400);
    expect(resendSend).not.toHaveBeenCalled();
    expect(fetchMock).not.toHaveBeenCalled();
  });

  test("rejects definitively undeliverable business email", async () => {
    const response = await POST(
      request(validLead({ businessEmail: "ada@nope.test" })),
    );

    expect(response.status).toBe(400);
    expect(await response.json()).toEqual({
      error: "Business email cannot receive mail",
    });
    expect(resendSend).not.toHaveBeenCalled();
    expect(fetchMock).not.toHaveBeenCalled();
  });

  test("emails founders, notifies Slack, and records PostHog", async () => {
    const response = await POST(request(validLead()));

    expect(response.status).toBe(200);
    expect(await response.json()).toEqual({
      ok: true,
      email: "sent",
      slack: "sent",
      posthog: "sent",
    });
    expect(resendCtor).toHaveBeenCalledWith("re_test");
    expect(resendSend).toHaveBeenCalledTimes(1);
    const resendCalls = (resendSend as unknown as {
      mock: { calls: Array<[Record<string, unknown>]> };
    }).mock.calls;
    expect(resendCalls[0]?.[0]).toMatchObject({
      to: ["founders@manaflow.com"],
      replyTo: "ada@good.test",
      subject: "Enterprise inquiry: Analytical Engines Inc.",
    });

    expect(fetchMock).toHaveBeenCalledTimes(2);
    const fetchCalls = (fetchMock as unknown as {
      mock: { calls: Array<[string | URL | Request, RequestInit?]> };
    }).mock.calls;
    expect(fetchCalls[0]?.[0]).toBe("https://slack.test/enterprise");
    const posthogBody = JSON.parse(
      (fetchCalls[1]?.[1] as RequestInit).body as string,
    );
    expect(posthogBody).toMatchObject({
      event: "cmux_enterprise_contact_submitted",
      distinct_id: "ada@good.test",
      properties: {
        companyName: "Analytical Engines Inc.",
        emailDomain: "good.test",
      },
    });
  });
});
