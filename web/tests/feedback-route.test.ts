const priorVercel = process.env.VERCEL;

import { afterAll, afterEach, describe, expect, mock, test } from "bun:test";
import {
  checkRateLimit,
  installVercelFirewallMock,
} from "./vercel-firewall-mock";

const sendEmail = mock(async () => ({ data: { id: "email-1" }, error: null }));

installVercelFirewallMock();

mock.module("resend", () => ({
  Resend: class {
    readonly emails = { send: sendEmail };
  },
}));

const { POST } = await import("../app/api/feedback/route");

afterEach(() => {
  checkRateLimit.mockClear();
  checkRateLimit.mockResolvedValue({ rateLimited: false, error: null });
  sendEmail.mockClear();
  if (priorVercel === undefined) {
    delete process.env.VERCEL;
  } else {
    process.env.VERCEL = priorVercel;
  }
});

afterAll(() => {
  restoreEnv("VERCEL", priorVercel);
});

describe("feedback route", () => {
  test("fails open when the Vercel firewall rule is missing", async () => {
    // A deleted rule is an operator action (no limit wanted), not an outage.
    process.env.VERCEL = "1";
    checkRateLimit.mockResolvedValue({ rateLimited: false, error: "not-found" });

    const res = await POST(feedbackRequest());

    expect(res.status).toBe(200);
    expect(await res.json()).toEqual({ ok: true });
    expect(sendEmail).toHaveBeenCalled();
  });

  test("fails closed when the Vercel firewall check errors", async () => {
    process.env.VERCEL = "1";
    checkRateLimit.mockResolvedValue({ rateLimited: false, error: "firewall-unavailable" });

    const res = await POST(feedbackRequest());

    expect(res.status).toBe(503);
    expect(await res.json()).toEqual({ error: "service_unavailable" });
    expect(sendEmail).not.toHaveBeenCalled();
  });
});

function feedbackRequest(): Request {
  const form = new FormData();
  form.set("email", "user@example.test");
  form.set("message", "The app crashed while opening a workspace.");
  return new Request("https://cmux.test/api/feedback", {
    method: "POST",
    body: form,
  });
}

function restoreEnv(key: string, value: string | undefined): void {
  if (value === undefined) {
    delete process.env[key];
    return;
  }
  process.env[key] = value;
}
