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

  test("fails open (unknown) when DNS exceeds the timeout", async () => {
    // A hung resolver must never reject a real address; the bounded check
    // resolves to "unknown" so the caller passes the email through. Capture the
    // abandoned lookups so they can be settled deterministically at the end
    // rather than left dangling across other test files in the shared process.
    const rejecters: Array<(reason: unknown) => void> = [];
    const lookups: Array<Promise<never>> = [];
    const hang = () => {
      const p = new Promise<never>((_, reject) => {
        rejecters.push(reject);
      });
      lookups.push(p);
      return p;
    };
    resolveMx = hang;
    resolve4 = hang;
    resolve6 = hang;
    expect(await checkEmailDeliverable("a@hung.test", 1)).toBe("unknown");
    // Settle the abandoned lookup so its in-flight entry clears and nothing
    // lingers for later tests.
    rejecters.forEach((reject) => reject(new Error("test cleanup")));
    await Promise.allSettled(lookups);
  });

  test("coalesces concurrent lookups for one domain onto a single DNS call", async () => {
    let mxCalls = 0;
    let release!: (v: { exchange: string; priority: number }[]) => void;
    resolveMx = () => {
      mxCalls += 1;
      return new Promise((res) => {
        release = res;
      });
    };
    resolve4 = noRecord;
    resolve6 = noRecord;
    // Each call runs synchronously up to its first await: the first invokes the
    // single resolveMx and registers the in-flight entry (so `release` is set);
    // the second coalesces onto it without calling resolveMx again. The dedupe
    // has therefore already happened by the time these two statements return —
    // no timer needed.
    const p1 = checkEmailDeliverable("a@coalesce.test");
    const p2 = checkEmailDeliverable("b@coalesce.test");
    release([{ exchange: "mx.coalesce.test", priority: 10 }]);
    expect(await p1).toBe("ok");
    expect(await p2).toBe("ok");
    expect(mxCalls).toBe(1);
  });
});
