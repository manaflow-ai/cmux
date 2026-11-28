import { afterEach, describe, expect, test } from "bun:test";
import { freestyleClient } from "../services/vms/drivers/freestyle";
import {
  FREESTYLE_BACKGROUND_HEADER,
  freestyleBackgroundFallbackFetch,
  type FreestyleBackgroundFallbackState,
} from "../services/vms/drivers/freestyleBackgroundFallback";

const storeUnavailable = () => Response.json(
  { code: "BACKGROUND_STORE_UNAVAILABLE", message: "Background requests are temporarily unavailable" },
  { status: 503 },
);

type Sent = {
  url: string; method: string; background: string | null; body: unknown;
  authorization: string | null; contentType: string | null;
};

function fakeProvider(answer: (sent: Sent, index: number) => Response) {
  const sent: Sent[] = [];
  const fetch = (async (input: RequestInfo | URL, init?: RequestInit) => {
    const headers = new Headers(init?.headers);
    const call = {
      url: String(input), method: init?.method ?? "GET",
      background: headers.get(FREESTYLE_BACKGROUND_HEADER), body: init?.body,
      authorization: headers.get("Authorization"), contentType: headers.get("Content-Type"),
    };
    sent.push(call);
    return answer(call, sent.length - 1);
  }) as typeof globalThis.fetch;
  return { sent, fetch };
}

describe("Freestyle background-store fallback", () => {
  const originalFetch = globalThis.fetch;
  const originalKey = process.env.FREESTYLE_API_KEY;
  afterEach(() => {
    globalThis.fetch = originalFetch;
    if (originalKey === undefined) delete process.env.FREESTYLE_API_KEY;
    else process.env.FREESTYLE_API_KEY = originalKey;
  });

  test("the driver's SDK client succeeds while the provider refuses background requests", async () => {
    process.env.FREESTYLE_API_KEY = "test-key";
    const provider = fakeProvider(sent => sent.background !== null
      ? storeUnavailable()
      : Response.json({ vms: [], totalCount: 0 }));
    globalThis.fetch = provider.fetch;

    const client = freestyleClient(5_000, new AbortController().signal);
    expect((await client.vms.list()).vms).toEqual([]);
    expect(provider.sent.map(sent => sent.background)).toEqual(["5", null]);

  });

  test("replays a POST body once without the header and keeps every other header", async () => {
    const provider = fakeProvider((_sent, index) => index === 0 ? storeUnavailable() : Response.json({ ok: true }));
    const state: FreestyleBackgroundFallbackState = { plainUntil: 0 };
    const wrapped = freestyleBackgroundFallbackFetch({ fetch: provider.fetch, state, now: () => 1_000 });
    const body = JSON.stringify({ command: "true" });
    const response = await wrapped("https://api.example.test/v5/vms/vm/exec-await", {
      method: "POST", body,
      headers: { Authorization: "Bearer k", "Content-Type": "application/json", [FREESTYLE_BACKGROUND_HEADER]: "5" },
    });
    expect(response.status).toBe(200);
    expect(provider.sent).toHaveLength(2);
    expect(provider.sent[1]).toMatchObject({
      method: "POST", background: null, body,
      authorization: "Bearer k", contentType: "application/json",
    });
    expect(state.plainUntil).toBe(61_000);
  });

  test("asks for background mode again after the cool-down", async () => {
    const provider = fakeProvider(() => Response.json({}));
    const state: FreestyleBackgroundFallbackState = { plainUntil: 61_000 };
    let now = 60_999;
    const wrapped = freestyleBackgroundFallbackFetch({ fetch: provider.fetch, state, now: () => now });
    const init = { headers: { [FREESTYLE_BACKGROUND_HEADER]: "5" } };
    await wrapped("https://api.example.test/v5/vms", init);
    now = 61_000;
    await wrapped("https://api.example.test/v5/vms", init);
    expect(provider.sent.map(sent => sent.background)).toEqual([null, "5"]);
  });

  test("returns any other 503, and a request without the header, unchanged", async () => {
    const other = Response.json({ code: "SERVICE_UNAVAILABLE" }, { status: 503 });
    const provider = fakeProvider((_sent, index) => index === 0 ? other : storeUnavailable());
    const state: FreestyleBackgroundFallbackState = { plainUntil: 0 };
    const wrapped = freestyleBackgroundFallbackFetch({ fetch: provider.fetch, state });
    expect(await wrapped("https://api.example.test/v5/vms", { headers: { [FREESTYLE_BACKGROUND_HEADER]: "5" } })).toBe(other);
    expect((await wrapped("https://api.example.test/v5/vms", { headers: {} })).status).toBe(503);
    expect(provider.sent).toHaveLength(2);
    expect(state.plainUntil).toBe(0);
  });
});
