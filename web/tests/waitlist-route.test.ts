// Skip env validation so importing the route doesn't require server secrets.
// Captured + restored in afterAll so the flag can't leak into other test files
// sharing this process and silently suppress their env validation.
const priorSkipEnvValidation = process.env.SKIP_ENV_VALIDATION;
const priorVercel = process.env.VERCEL;
process.env.SKIP_ENV_VALIDATION = "1";
process.env.VERCEL = "0";

import { afterAll, beforeEach, describe, expect, mock, test } from "bun:test";

afterAll(() => {
  if (priorSkipEnvValidation === undefined) {
    delete process.env.SKIP_ENV_VALIDATION;
  } else {
    process.env.SKIP_ENV_VALIDATION = priorSkipEnvValidation;
  }
  if (priorVercel === undefined) {
    delete process.env.VERCEL;
  } else {
    process.env.VERCEL = priorVercel;
  }
});

function dnsError(code: string): NodeJS.ErrnoException {
  const err = new Error(code) as NodeJS.ErrnoException;
  err.code = code;
  return err;
}

// good.test has an MX; everything else has no records (undeliverable).
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

const { POST } = await import("../app/api/waitlist/route");

function post(body: unknown): Request {
  return new Request("https://cmux.test/api/waitlist", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(body),
  });
}

describe("waitlist route", () => {
  beforeEach(() => {
    process.env.VERCEL = "0";
  });

  test("accepts a deliverable email in the validate phase", async () => {
    const res = await POST(
      post({ email: "a@good.test", platforms: ["linux"], notify: false }),
    );
    expect(res.status).toBe(200);
    expect(await res.json()).toEqual({
      ok: true,
      valid: true,
      slack: "skipped",
    });
  });

  test("rejects an undeliverable email without recording", async () => {
    const res = await POST(
      post({ email: "a@nope.test", platforms: ["linux"], notify: false }),
    );
    expect(res.status).toBe(200);
    expect(await res.json()).toEqual({ ok: true, valid: false });
  });

  test("rejects a disposable email", async () => {
    const res = await POST(
      post({ email: "a@mailinator.com", platforms: ["windows"] }),
    );
    expect(res.status).toBe(200);
    expect(await res.json()).toEqual({ ok: true, valid: false });
  });

  test("rejects a malformed payload with 400", async () => {
    const res = await POST(post({ email: "not-an-email", platforms: [] }));
    expect(res.status).toBe(400);
  });
});
