import { expect, test } from "bun:test";
import { observe } from "../src/observability";

test("observability redacts sensitive fields and exports without blocking", async () => {
  const requests: Request[] = [];
  const originalFetch = globalThis.fetch;
  globalThis.fetch = (async (input, init) => {
    requests.push(new Request(input, init));
    return new Response("{}", { status: 200 });
  }) as typeof fetch;
  try {
    const pending: Promise<unknown>[] = [];
    observe({ waitUntil: promise => pending.push(promise) }, {
      ENVIRONMENT: "test", AXIOM_DATASET: "test", AXIOM_INGEST_URL: "https://axiom.test/ingest",
      AXIOM_TOKEN: "secret-token", SENTRY_DSN: "https://public@sentry.test/42", SENTRY_ENVIRONMENT: "test",
    } as any, {
      event: "iroh.http.failure", status: 401, authorization: "Bearer private", body: "terminal output", code: "unauthorized",
    });
    await Promise.all(pending);
    expect(requests).toHaveLength(1);
    const axiom = JSON.parse(await requests[0]!.clone().text())[0];
    expect(axiom.authorization).toBeUndefined();
    expect(axiom.body).toBeUndefined();
    expect(axiom.code).toBe("unauthorized");
    expect(requests[0]!.headers.get("authorization")).toBe("Bearer secret-token");
  } finally {
    globalThis.fetch = originalFetch;
  }
});

test("unexpected failures go to Sentry while routine denials stay in Axiom", async () => {
  const requests: Request[] = [];
  const originalFetch = globalThis.fetch;
  globalThis.fetch = (async (input, init) => { requests.push(new Request(input, init)); return new Response("ok"); }) as typeof fetch;
  try {
    const pending: Promise<unknown>[] = [];
    const env = { ENVIRONMENT: "test", AXIOM_DATASET: "test", AXIOM_INGEST_URL: "https://axiom.test/ingest", AXIOM_TOKEN: "a", SENTRY_DSN: "https://public@sentry.test/42" } as any;
    observe({ waitUntil: promise => pending.push(promise) }, env, { event: "iroh.http.failure", status: 403, code: "permission_denied" });
    observe({ waitUntil: promise => pending.push(promise) }, env, { event: "iroh.http.failure", status: 500, code: "internal_error" });
    await Promise.all(pending);
    expect(requests).toHaveLength(3);
  } finally { globalThis.fetch = originalFetch; }
});

test("sink concurrency is finite and reports dropped events", async () => {
  const originalFetch = globalThis.fetch;
  let release!: () => void;
  const gate = new Promise<void>(resolve => { release = resolve; });
  globalThis.fetch = (async () => { await gate; return new Response("ok"); }) as unknown as typeof fetch;
  try {
    const pending: Promise<unknown>[] = [];
    const env = { ENVIRONMENT: "test", AXIOM_DATASET: "test", AXIOM_TOKEN: "a" } as any;
    for (let index = 0; index < 24; index += 1) observe({ waitUntil: promise => pending.push(promise) }, env, { event: "iroh.http.response", status: 200, index });
    expect(pending.length).toBe(16);
    release();
    await Promise.all(pending);
  } finally { globalThis.fetch = originalFetch; }
});

test("sink failures are contained and still use waitUntil", async () => {
  const originalFetch = globalThis.fetch;
  globalThis.fetch = (async () => { throw new Error("offline"); }) as unknown as typeof fetch;
  try {
    const pending: Promise<unknown>[] = [];
    expect(() => observe({ waitUntil: promise => pending.push(promise) }, {
      ENVIRONMENT: "test", AXIOM_DATASET: "test", AXIOM_TOKEN: "secret-token",
    } as any, { event: "iroh.http.response", status: 200 })).not.toThrow();
    await Promise.all(pending);
  } finally {
    globalThis.fetch = originalFetch;
  }
});
