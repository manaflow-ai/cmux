const priorSkipEnvValidation = process.env.SKIP_ENV_VALIDATION;
const priorVercel = process.env.VERCEL;

process.env.SKIP_ENV_VALIDATION = "1";

import { afterAll, afterEach, describe, expect, mock, test } from "bun:test";
import {
  checkRateLimit,
  installVercelFirewallMock,
} from "./vercel-firewall-mock";

type SentEmail = {
  to: string[];
  replyTo?: string;
  subject: string;
  text: string;
  attachments?: { filename: string }[];
};

const sentEmails: SentEmail[] = [];
const sendEmail = mock(async (message: unknown) => {
  sentEmails.push(message as SentEmail);
  return { data: { id: "email-1" }, error: null };
});

installVercelFirewallMock();

mock.module("@/app/env", () => ({
  env: {
    RESEND_API_KEY: "resend-test-key",
    CMUX_FEEDBACK_FROM_EMAIL: "feedback@example.test",
    CMUX_FEEDBACK_RATE_LIMIT_ID: "feedback-rate-limit-test",
  },
}));

mock.module("resend", () => ({
  Resend: class {
    readonly emails = { send: sendEmail };
  },
}));

const { POST } = await import("../app/api/hang-report/route");

afterEach(() => {
  checkRateLimit.mockClear();
  checkRateLimit.mockResolvedValue({ rateLimited: false, error: null });
  sendEmail.mockClear();
  sentEmails.length = 0;
  if (priorVercel === undefined) {
    delete process.env.VERCEL;
  } else {
    process.env.VERCEL = priorVercel;
  }
});

afterAll(() => {
  restoreEnv("SKIP_ENV_VALIDATION", priorSkipEnvValidation);
  restoreEnv("VERCEL", priorVercel);
});

describe("hang report route", () => {
  test("fails closed when the Vercel firewall rule is missing", async () => {
    process.env.VERCEL = "1";
    checkRateLimit.mockResolvedValue({ rateLimited: false, error: "not-found" });

    const res = await POST(hangReportRequest({ archive: gzipFile() }));

    expect(res.status).toBe(503);
    expect(await res.json()).toEqual({ error: "service_unavailable" });
    expect(sendEmail).not.toHaveBeenCalled();
  });

  test("rejects a report with neither archive nor gist URL", async () => {
    const res = await POST(hangReportRequest({}));

    expect(res.status).toBe(400);
    expect(sendEmail).not.toHaveBeenCalled();
  });

  test("rejects an archive that is not gzip data", async () => {
    const res = await POST(
      hangReportRequest({
        archive: new File([Buffer.from("plain text, not gzip")], "evidence.tar.gz", {
          type: "application/gzip",
        }),
      }),
    );

    expect(res.status).toBe(415);
    expect(sendEmail).not.toHaveBeenCalled();
  });

  test("rejects an oversized archive", async () => {
    const oversized = Buffer.alloc(Math.floor(3.5 * 1024 * 1024) + 1);
    oversized[0] = 0x1f;
    oversized[1] = 0x8b;
    const res = await POST(
      hangReportRequest({
        archive: new File([oversized], "evidence.tar.gz", { type: "application/gzip" }),
      }),
    );

    expect(res.status).toBe(413);
    expect(sendEmail).not.toHaveBeenCalled();
  });

  test("rejects a non-gist URL", async () => {
    const res = await POST(
      hangReportRequest({ gistUrl: "https://example.com/evil" }),
    );

    expect(res.status).toBe(400);
    expect(sendEmail).not.toHaveBeenCalled();
  });

  test("sends an archive report to founders@manaflow.ai", async () => {
    const res = await POST(
      hangReportRequest({ archive: gzipFile(), email: "user@example.test" }),
    );

    expect(res.status).toBe(200);
    expect(await res.json()).toEqual({ ok: true });
    expect(sentEmails).toHaveLength(1);
    const message = sentEmails[0];
    expect(message.to).toEqual(["founders@manaflow.ai"]);
    expect(message.replyTo).toBe("user@example.test");
    expect(message.subject).toContain("cmux hang report");
    expect(message.attachments?.[0]?.filename).toBe("cmux-hang-20260717.tar.gz");
  });

  test("sends a gist-only report without attachments", async () => {
    const res = await POST(
      hangReportRequest({ gistUrl: "https://gist.github.com/someone/abc123" }),
    );

    expect(res.status).toBe(200);
    expect(sentEmails).toHaveLength(1);
    const message = sentEmails[0];
    expect(message.attachments).toBeUndefined();
    expect(message.replyTo).toBeUndefined();
    expect(message.text).toContain("https://gist.github.com/someone/abc123");
  });
});

function gzipFile(): File {
  const gzipBytes = Buffer.from([0x1f, 0x8b, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00]);
  return new File([gzipBytes], "cmux-hang-20260717.tar.gz", {
    type: "application/gzip",
  });
}

function hangReportRequest(input: {
  archive?: File;
  email?: string;
  gistUrl?: string;
}): Request {
  const form = new FormData();
  form.set("summary", "Main thread blocked in __psynch_mutexwait under WorkspaceStore.");
  if (input.archive) {
    form.set("archive", input.archive);
  }
  if (input.email) {
    form.set("email", input.email);
  }
  if (input.gistUrl) {
    form.set("gistUrl", input.gistUrl);
  }
  return new Request("https://cmux.test/api/hang-report", {
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
