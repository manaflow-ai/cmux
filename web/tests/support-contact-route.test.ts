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

mock.module("resend", () => ({
  Resend: class MockResend {
    emails = { send: resendSend };

    constructor(apiKey: string) {
      resendCtor(apiKey);
    }
  },
}));

const { POST } = await import("../app/api/support/contact/route");

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
  return new Request("https://cmux.test/api/support/contact", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(body),
  });
}

function validRequest(overrides: Record<string, unknown> = {}) {
  return {
    name: "Ada Lovelace",
    email: "ada@good.test",
    topic: "Bug report",
    message: "The terminal stopped responding after reconnecting.",
    source: "support_page",
    ...overrides,
  };
}

describe("support contact route", () => {
  test("requires an email and message", async () => {
    const response = await POST(request({ email: "ada@good.test" }));

    expect(response.status).toBe(400);
    expect(resendSend).not.toHaveBeenCalled();
    expect(fetchMock).not.toHaveBeenCalled();
  });

  test("rejects definitively undeliverable email", async () => {
    const response = await POST(
      request(validRequest({ email: "ada@nope.test" })),
    );

    expect(response.status).toBe(400);
    expect(await response.json()).toEqual({
      error: "Email address cannot receive mail",
    });
    expect(resendSend).not.toHaveBeenCalled();
    expect(fetchMock).not.toHaveBeenCalled();
  });

  test("emails founders, notifies Slack, and records PostHog", async () => {
    const response = await POST(request(validRequest()));

    expect(response.status).toBe(200);
    expect(await response.json()).toEqual({
      ok: true,
      email: "sent",
      slack: "sent",
      posthog: "sent",
    });
    expect(resendSend).toHaveBeenCalledTimes(1);
    const resendCalls = (resendSend as unknown as {
      mock: { calls: Array<[Record<string, unknown>]> };
    }).mock.calls;
    expect(resendCalls[0]?.[0]).toMatchObject({
      to: ["founders@manaflow.com"],
      replyTo: "ada@good.test",
      subject: "Support request (Bug report): ada@good.test",
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
      event: "cmux_support_request_submitted",
      distinct_id: "ada@good.test",
      properties: {
        topic: "Bug report",
        emailDomain: "good.test",
      },
    });
  });

  test("does not ask the user to retry after a post-email Slack failure", async () => {
    let fetchCount = 0;
    mockImplementation(fetchMock, async () => {
      fetchCount += 1;
      return fetchCount === 1
        ? new Response("slack down", { status: 500 })
        : new Response("ok", { status: 200 });
    });
    const originalError = console.error;
    console.error = mock(() => {}) as unknown as typeof console.error;
    try {
      const response = await POST(request(validRequest()));

      expect(response.status).toBe(200);
      expect(await response.json()).toEqual({
        ok: true,
        email: "sent",
        slack: "failed",
        posthog: "sent",
      });
      expect(resendSend).toHaveBeenCalledTimes(1);
      expect(fetchMock).toHaveBeenCalledTimes(2);
    } finally {
      console.error = originalError;
    }
  });
});

function mockImplementation(
  fn: unknown,
  implementation: (...args: never[]) => unknown,
) {
  (fn as { mockImplementation(next: typeof implementation): void }).mockImplementation(
    implementation,
  );
}
