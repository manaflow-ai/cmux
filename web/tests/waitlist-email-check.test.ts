import { describe, expect, mock, test } from "bun:test";

// Controllable DNS responders; each test sets the behaviour it needs. Mocked
// before importing the module under test so the import binds to these.
let resolveMx: (
  domain: string,
) => Promise<{ exchange: string; priority: number }[]>;
let resolve4: (domain: string) => Promise<string[]>;
let resolve6: (domain: string) => Promise<string[]>;

mock.module("node:dns", () => ({
  promises: {
    resolveMx: (d: string) => resolveMx(d),
    resolve4: (d: string) => resolve4(d),
    resolve6: (d: string) => resolve6(d),
  },
}));

const { checkEmailDeliverable } = await import(
  "../app/api/waitlist/email-check"
);

function dnsError(code: string): NodeJS.ErrnoException {
  const err = new Error(code) as NodeJS.ErrnoException;
  err.code = code;
  return err;
}

const noRecord = async (): Promise<never> => {
  throw dnsError("ENOTFOUND");
};

describe("checkEmailDeliverable", () => {
  test("accepts a domain with a usable MX record", async () => {
    resolveMx = async () => [{ exchange: "mx.test", priority: 10 }];
    resolve4 = noRecord;
    resolve6 = noRecord;
    expect(await checkEmailDeliverable("a@mx-ok.test")).toBe("ok");
  });

  test("rejects a domain with no MX and no address record", async () => {
    resolveMx = noRecord;
    resolve4 = noRecord;
    resolve6 = noRecord;
    expect(await checkEmailDeliverable("a@nope.test")).toBe("invalid");
  });

  test("falls back to an A record when there is no MX (RFC 5321)", async () => {
    resolveMx = async () => {
      throw dnsError("ENODATA");
    };
    resolve4 = async () => ["203.0.113.5"];
    resolve6 = noRecord;
    expect(await checkEmailDeliverable("a@a-only.test")).toBe("ok");
  });

  test("rejects an explicit null MX (RFC 7505)", async () => {
    resolveMx = async () => [{ exchange: ".", priority: 0 }];
    resolve4 = noRecord;
    resolve6 = noRecord;
    expect(await checkEmailDeliverable("a@null-mx.test")).toBe("invalid");
  });

  test("fails open (unknown) on a transient resolver error", async () => {
    resolveMx = async () => {
      throw dnsError("ETIMEOUT");
    };
    resolve4 = noRecord;
    resolve6 = noRecord;
    expect(await checkEmailDeliverable("a@flaky.test")).toBe("unknown");
  });

  test("rejects a known disposable domain without any DNS lookup", async () => {
    const boom = async (): Promise<never> => {
      throw new Error("DNS should not be queried for a disposable domain");
    };
    resolveMx = boom;
    resolve4 = boom;
    resolve6 = boom;
    expect(await checkEmailDeliverable("a@mailinator.com")).toBe("invalid");
  });

  test("rejects malformed input with no @", async () => {
    resolveMx = noRecord;
    resolve4 = noRecord;
    resolve6 = noRecord;
    expect(await checkEmailDeliverable("not-an-email")).toBe("invalid");
  });
});
