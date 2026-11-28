import { afterEach, describe, expect, test } from "bun:test";
import { freestyleClient } from "../services/vms/drivers/freestyle";

const BACKGROUND_HEADER = "x-freestyle-background-after-secs";

type Sent = { readonly method: string; readonly background: string | null; readonly body: unknown };

function fakeProvider(answer: (sent: Sent, index: number) => Response) {
  const sent: Sent[] = [];
  const fetch = (async (_input: RequestInfo | URL, init?: RequestInit) => {
    const call = {
      method: init?.method ?? "GET",
      background: new Headers(init?.headers).get(BACKGROUND_HEADER),
      body: init?.body,
    };
    sent.push(call);
    return answer(call, sent.length - 1);
  }) as typeof globalThis.fetch;
  return { sent, fetch };
}

const storeUnavailable = () => Response.json(
  { code: "BACKGROUND_STORE_UNAVAILABLE", message: "Background requests are temporarily unavailable" },
  { status: 503 },
);
const execResult = () => Response.json({ statusCode: 0, stdout: "", stderr: "" });

describe("Freestyle background-store fallback", () => {
  const originalFetch = globalThis.fetch;
  const originalNow = Date.now;
  const originalKey = process.env.FREESTYLE_API_KEY;
  afterEach(() => {
    globalThis.fetch = originalFetch;
    Date.now = originalNow;
    if (originalKey === undefined) delete process.env.FREESTYLE_API_KEY;
    else process.env.FREESTYLE_API_KEY = originalKey;
  });

  test("replays a refused exec once without the header, then skips it for the cool-down", async () => {
    process.env.FREESTYLE_API_KEY = "test-key";
    // Far from any earlier test's cool-down window in this process.
    let now = 10_000_000_000;
    Date.now = () => now;
    let storeDown = true;
    const provider = fakeProvider(sent => storeDown && sent.background !== null ? storeUnavailable() : execResult());
    globalThis.fetch = provider.fetch;
    const vm = freestyleClient(5_000, new AbortController().signal).vms.ref("vm-1");

    expect((await vm.exec("true")).statusCode).toBe(0);
    expect(provider.sent.map(sent => [sent.method, sent.background])).toEqual([["POST", "5"], ["POST", null]]);
    expect(provider.sent[1]?.body).toBe(provider.sent[0]?.body);

    now += 59_000;
    await vm.exec("true");
    expect(provider.sent.map(sent => sent.background)).toEqual(["5", null, null]);

    storeDown = false;
    now += 2_000;
    await vm.exec("true");
    expect(provider.sent.map(sent => sent.background)).toEqual(["5", null, null, "5"]);
  });

  test("does not replay any other 503", async () => {
    process.env.FREESTYLE_API_KEY = "test-key";
    Date.now = () => 20_000_000_000;
    const provider = fakeProvider(() => Response.json({ code: "SERVICE_UNAVAILABLE" }, { status: 503 }));
    globalThis.fetch = provider.fetch;
    const vm = freestyleClient(5_000, new AbortController().signal).vms.ref("vm-1");

    await expect(vm.exec("true")).rejects.toThrow();
    expect(provider.sent.map(sent => sent.background)).toEqual(["5"]);
  });
});
