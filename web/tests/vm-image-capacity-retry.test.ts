import { describe, expect, test } from "bun:test";
import { Freestyle } from "freestyle";
import { freestyleClient } from "../scripts/cmux-vm-image/guest";
import { CAPACITY_RETRY_DELAYS_MS, capacityRetryFetch, installCapacityRetry, isBackgroundUnavailableAnswer, isCapacityAnswer } from "../scripts/cmux-vm-image/capacity";

// The provider's answer in the image roll's failed runs on 2026-11-16 (jobs 133426693737, 133432870475,
// 133444252629, 133446604123): FreestyleApiError status 429, code TOO_MANY_REQUESTS.
const CAPACITY_BODY = JSON.stringify({ code: "TOO_MANY_REQUESTS", message: "server is at capacity; try again shortly" });
const capacity = () => new Response(CAPACITY_BODY, { status: 429, headers: { "content-type": "application/json" } });
// Image roll 45957567838 (job 140367707448, 2026-11-27 07:32Z): "FreestyleApiError: Background requests are
// temporarily unavailable" 4.2 s into the bake's identity-final exec; the log does not carry the status.
const BG_UNAVAILABLE_BODY = JSON.stringify({ code: "SERVICE_UNAVAILABLE", message: "Background requests are temporarily unavailable" });
const bgUnavailable = (status = 503) => () => new Response(BG_UNAVAILABLE_BODY, { status, headers: { "content-type": "application/json" } });
const json = (value: unknown, status = 200) => new Response(JSON.stringify(value), { status, headers: { "content-type": "application/json" } });

/** A provider that answers each call from `script` in turn and records what it was sent. */
function provider(script: Array<() => Response>) {
  const calls: Array<{ method: string; path: string; body: string | null }> = [];
  const fetch = async (input: string | URL | Request, init?: RequestInit) => {
    const url = typeof input === "string" ? input : input instanceof URL ? input.href : input.url;
    calls.push({ method: (init?.method ?? "GET").toUpperCase(), path: new URL(url).pathname, body: typeof init?.body === "string" ? init.body : null });
    const next = script.shift();
    if (!next) throw new Error(`unexpected call ${url}`);
    return next();
  };
  return { fetch, calls };
}

function recorder() {
  const waits: number[] = [];
  const lines: string[] = [];
  return { waits, lines, deps: { sleep: async (ms: number) => void waits.push(ms), log: (line: string) => void lines.push(line) } };
}

describe("the provider's capacity answer", () => {
  test("is a 429 that says at capacity", () => {
    expect(isCapacityAnswer(429, CAPACITY_BODY)).toBe(true);
    expect(isCapacityAnswer(429, "server is at capacity; try again shortly")).toBe(true);
    expect(isCapacityAnswer(429, JSON.stringify({ code: "TOO_MANY_REQUESTS", message: "rate limit exceeded for this key" }))).toBe(false);
    expect(isCapacityAnswer(503, CAPACITY_BODY)).toBe(false);
    expect(isCapacityAnswer(400, CAPACITY_BODY)).toBe(false);
  });

  test("is the VM start's 429 INFRASTRUCTURE_OVERLOADED (image roll run 45954186557, 2026-11-27)", () => {
    const overloaded = JSON.stringify({ code: "INFRASTRUCTURE_OVERLOADED", message: "infrastructure overloaded: VM start capacity queue wait expired" });
    expect(isCapacityAnswer(429, overloaded)).toBe(true);
    expect(isCapacityAnswer(429, JSON.stringify({ code: "INFRASTRUCTURE_OVERLOADED" }))).toBe(true);
    expect(isCapacityAnswer(429, "infrastructure overloaded: VM start capacity queue wait expired")).toBe(true);
    expect(isCapacityAnswer(503, overloaded)).toBe(false);
  });

  test("the background-request refusal is retried whatever its error status (image roll 45957567838)", () => {
    for (const status of [429, 500, 503]) expect(isBackgroundUnavailableAnswer(status, BG_UNAVAILABLE_BODY)).toBe(true);
    expect(isBackgroundUnavailableAnswer(503, "Background requests are temporarily unavailable")).toBe(true);
    expect(isBackgroundUnavailableAnswer(200, BG_UNAVAILABLE_BODY)).toBe(false);
    expect(isBackgroundUnavailableAnswer(503, JSON.stringify({ message: "service unavailable" }))).toBe(false);
    // the SDK's own poll-hop message is not the provider's refusal
    expect(isBackgroundUnavailableAnswer(503, "Background request temporarily unavailable (503)")).toBe(false);
  });

  test("the retry budget stays a few minutes, so an outage still fails", () => {
    const total = CAPACITY_RETRY_DELAYS_MS.reduce((a, b) => a + b, 0);
    expect(total).toBeGreaterThanOrEqual(120_000);
    expect(total).toBeLessThanOrEqual(300_000);
  });
});

describe("capacityRetryFetch", () => {
  test("a capacity answer is sent again after a wait, and the answer after it goes to the caller", async () => {
    const p = provider([capacity, capacity, () => json({ ok: true })]);
    const r = recorder();
    const response = await capacityRetryFetch(p.fetch, r.deps)("https://api.example/v5/vms/vm-1/exec-await", { method: "POST", body: '{"command":"true"}' });
    expect(response.status).toBe(200);
    expect(p.calls.map((c) => c.body)).toEqual(['{"command":"true"}', '{"command":"true"}', '{"command":"true"}']);
    expect(r.waits).toEqual(CAPACITY_RETRY_DELAYS_MS.slice(0, 2));
    expect(r.lines[0]).toContain("PROVIDER AT CAPACITY: POST /v5/vms/vm-1/exec-await answered 429; retry 1/");
  });

  test("past the budget the last capacity answer goes to the caller", async () => {
    const p = provider(Array.from({ length: CAPACITY_RETRY_DELAYS_MS.length + 1 }, () => capacity));
    const r = recorder();
    const response = await capacityRetryFetch(p.fetch, r.deps)("https://api.example/v5/vms/vm-1", { method: "DELETE" });
    expect(response.status).toBe(429);
    expect(await response.text()).toBe(CAPACITY_BODY);
    expect(p.calls).toHaveLength(CAPACITY_RETRY_DELAYS_MS.length + 1);
  });

  test("Retry-After lengthens a wait up to the cap", async () => {
    const p = provider([() => new Response(CAPACITY_BODY, { status: 429, headers: { "retry-after": "30" } }), () => new Response(CAPACITY_BODY, { status: 429, headers: { "retry-after": "600" } }), () => json({})]);
    const r = recorder();
    await capacityRetryFetch(p.fetch, r.deps)("https://api.example/v5/vms", { method: "POST", body: "{}" });
    expect(r.waits).toEqual([30_000, 60_000]);
  });

  test("anything else is the caller's: another 429, a 5xx, a stored background answer, a streamed body", async () => {
    const r = recorder();
    const rateLimited = provider([() => json({ code: "TOO_MANY_REQUESTS", message: "rate limit exceeded" }, 429)]);
    expect((await capacityRetryFetch(rateLimited.fetch, r.deps)("https://api.example/v5/vms", { method: "POST", body: "{}" })).status).toBe(429);
    const unavailable = provider([() => json({ message: "server is at capacity" }, 503)]);
    expect((await capacityRetryFetch(unavailable.fetch, r.deps)("https://api.example/v5/vms", { method: "POST", body: "{}" })).status).toBe(503);
    // A background request's stored answer belongs to a request that ran: never sent again.
    const stored = provider([() => new Response(CAPACITY_BODY, { status: 429, headers: { "x-freestyle-background-request-id": "br-1" } })]);
    expect((await capacityRetryFetch(stored.fetch, r.deps)("https://api.example/v5/vms/vm-1/exec-await", { method: "POST", body: "{}" })).status).toBe(429);
    const streamed = provider([capacity]);
    const body = new ReadableStream({ start: (c) => c.close() });
    expect((await capacityRetryFetch(streamed.fetch, r.deps)("https://api.example/v5/vms/vm-1/fs/write", { method: "PUT", body })).status).toBe(429);
    expect(r.waits).toEqual([]);
  });
});

describe("the image scripts' client retries a capacity answer on every call the roll failed on", () => {
  const client = (p: ReturnType<typeof provider>, r: ReturnType<typeof recorder>) =>
    installCapacityRetry(new Freestyle({ apiKey: "test", baseUrl: "https://api.example", fetch: p.fetch as unknown as typeof fetch }), r.deps);

  test("exec (the smoke and probe steps)", async () => {
    const p = provider([capacity, () => json({ statusCode: 0, stdout: "ok\n", stderr: "" })]);
    const r = recorder();
    const result = await client(p, r).vms.ref("vm-1").exec({ command: "echo ok" });
    expect(result.stdout).toBe("ok\n");
    expect(p.calls.map((c) => `${c.method} ${c.path}`)).toEqual(["POST /v5/vms/vm-1/exec-await", "POST /v5/vms/vm-1/exec-await"]);
  });

  test("a guest file write (the bake's host config, job 133444252629)", async () => {
    const p = provider([capacity, capacity, () => new Response(null, { status: 204 })]);
    const r = recorder();
    await client(p, r).vms.ref("vm-1").fs.writeFile("/etc/cmux/host.json", "{}", { mode: 0o644 });
    expect(p.calls.map((c) => `${c.method} ${c.path}`)).toEqual(Array(3).fill("PUT /v5/vms/vm-1/fs/write"));
  });

  test("the VM delete after a passing smoke (job 133426693737)", async () => {
    const p = provider([capacity, () => new Response(null, { status: 204 })]);
    const r = recorder();
    await client(p, r).vms.ref("vm-007997e5db1e47afa35bb37b6b0a36b9").delete();
    expect(p.calls.map((c) => `${c.method} ${c.path}`)).toEqual(Array(2).fill("DELETE /v5/vms/vm-007997e5db1e47afa35bb37b6b0a36b9"));
  });

  test("an outage longer than the budget still throws today's FreestyleApiError", async () => {
    const p = provider(Array.from({ length: CAPACITY_RETRY_DELAYS_MS.length + 1 }, () => capacity));
    const r = recorder();
    const error = await client(p, r).vms.ref("vm-1").delete().catch((e: unknown) => e);
    expect(String(error)).toBe("FreestyleApiError: server is at capacity; try again shortly");
    expect((error as { status: number }).status).toBe(429);
    expect(r.waits).toEqual([...CAPACITY_RETRY_DELAYS_MS]);
  });

  test("the bake's exec refused with background requests unavailable is sent again (job 140367707448)", async () => {
    const p = provider([bgUnavailable(), bgUnavailable(), () => json({ statusCode: 0, stdout: "ok\n", stderr: "" })]);
    const r = recorder();
    const result = await client(p, r).vms.ref("vm-1").exec({ command: "echo ok" });
    expect(result.stdout).toBe("ok\n");
    expect(p.calls.map((c) => `${c.method} ${c.path}`)).toEqual(Array(3).fill("POST /v5/vms/vm-1/exec-await"));
    expect(r.lines[0]).toContain("PROVIDER BACKGROUND UNAVAILABLE: POST /v5/vms/vm-1/exec-await answered 503; retry 1/");
  });

  test("a stored answer carrying the background request id is never sent again, even saying background unavailable", async () => {
    const p = provider([() => new Response(BG_UNAVAILABLE_BODY, { status: 503, headers: { "x-freestyle-background-request-id": "br-1" } })]);
    const r = recorder();
    const response = await capacityRetryFetch(p.fetch, r.deps)("https://api.example/v5/vms/vm-1/exec-await", { method: "POST", body: "{}" });
    expect(response.status).toBe(503);
    expect(p.calls).toHaveLength(1);
  });

  test("a step that ran and failed is not sent again", async () => {
    const p = provider([() => json({ statusCode: 2, stdout: "", stderr: "boom" })]);
    const r = recorder();
    const result = await client(p, r).vms.ref("vm-1").exec({ command: "false" });
    expect(result.statusCode).toBe(2);
    expect(p.calls).toHaveLength(1);
    expect(r.waits).toEqual([]);
  });
});

test("freestyleClient, the client every image script makes, carries the retry", () => {
  const saved = process.env.FREESTYLE_API_KEY;
  process.env.FREESTYLE_API_KEY = "test";
  let client: { client: { fetchImpl: unknown } };
  try {
    client = freestyleClient() as unknown as typeof client;
  } finally {
    if (saved === undefined) delete process.env.FREESTYLE_API_KEY;
    else process.env.FREESTYLE_API_KEY = saved;
  }
  expect(String(client.client.fetchImpl)).toContain("canRetry");
});
