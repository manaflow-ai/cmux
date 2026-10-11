// A worked turn that edits three files: the prompt, the agent's edits (each a real before and
// after), and its summary. The preview's "Worked turn" fixture and `debug.agent_pane seed_rows`
// with `fixture: "worked-turn"` show it, for the changes view and its captures.
import type { AcpmuxRow } from "./model";

const clientBefore = `import { parseError } from "./errors";

export type FetchOptions = {
  method?: "GET" | "POST";
  body?: unknown;
  signal?: AbortSignal;
};

export async function request<T>(url: string, options: FetchOptions = {}): Promise<T> {
  const response = await fetch(url, {
    method: options.method ?? "GET",
    headers: { "content-type": "application/json" },
    body: options.body === undefined ? undefined : JSON.stringify(options.body),
    signal: options.signal,
  });
  if (!response.ok) throw await parseError(response);
  return (await response.json()) as T;
}

export function getJSON<T>(url: string, signal?: AbortSignal): Promise<T> {
  return request<T>(url, { signal });
}

export function postJSON<T>(url: string, body: unknown): Promise<T> {
  return request<T>(url, { method: "POST", body });
}
`;

const clientAfter = `import { parseError } from "./errors";
import { withRetry, type RetryPolicy } from "./retry";

export type FetchOptions = {
  method?: "GET" | "POST";
  body?: unknown;
  signal?: AbortSignal;
  retry?: RetryPolicy | false;
};

const RETRYABLE = new Set([408, 429, 502, 503, 504]);

export async function request<T>(url: string, options: FetchOptions = {}): Promise<T> {
  const send = async () => {
    const response = await fetch(url, {
      method: options.method ?? "GET",
      headers: { "content-type": "application/json" },
      body: options.body === undefined ? undefined : JSON.stringify(options.body),
      signal: options.signal,
    });
    if (RETRYABLE.has(response.status)) throw await parseError(response, { retryable: true });
    if (!response.ok) throw await parseError(response);
    return (await response.json()) as T;
  };
  // Only GETs repeat on their own; a POST retries only when the caller asks.
  const policy = options.retry ?? (options.method === "POST" ? false : undefined);
  return policy === false ? send() : withRetry(send, { ...policy, signal: options.signal });
}

export function getJSON<T>(url: string, signal?: AbortSignal): Promise<T> {
  return request<T>(url, { signal });
}

export function postJSON<T>(url: string, body: unknown, retry?: RetryPolicy): Promise<T> {
  return request<T>(url, { method: "POST", body, retry: retry ?? false });
}
`;

const retryBefore = `export type RetryPolicy = {
  attempts?: number;
};
`;

const retryAfter = `export type RetryPolicy = {
  /** Tries in all, the first included. */
  attempts?: number;
  /** The first wait; each later wait doubles, up to maxDelayMs. */
  baseDelayMs?: number;
  maxDelayMs?: number;
  signal?: AbortSignal;
};

const sleep = (ms: number, signal?: AbortSignal) =>
  new Promise<void>((resolve, reject) => {
    const timer = setTimeout(resolve, ms);
    signal?.addEventListener("abort", () => {
      clearTimeout(timer);
      reject(signal.reason);
    });
  });

/** Runs \`task\` until it succeeds, throws a non-retryable error, or runs out of attempts. */
export async function withRetry<T>(task: () => Promise<T>, policy: RetryPolicy = {}): Promise<T> {
  const { attempts = 3, baseDelayMs = 250, maxDelayMs = 4_000, signal } = policy;
  for (let attempt = 1; ; attempt += 1) {
    try {
      return await task();
    } catch (error) {
      const retryable = (error as { retryable?: boolean }).retryable === true;
      if (!retryable || attempt >= attempts || signal?.aborted) throw error;
      const jitter = Math.random() * baseDelayMs;
      await sleep(Math.min(maxDelayMs, baseDelayMs * 2 ** (attempt - 1)) + jitter, signal);
    }
  }
}
`;

const testBefore = `import { describe, expect, test } from "bun:test";
import { getJSON } from "./client";

describe("getJSON", () => {
  test("returns the parsed body", async () => {
    mockFetch([{ status: 200, body: { ok: true } }]);
    expect(await getJSON("/health")).toEqual({ ok: true });
  });
});
`;

const testAfter = `import { describe, expect, test } from "bun:test";
import { getJSON, postJSON } from "./client";

describe("getJSON", () => {
  test("returns the parsed body", async () => {
    mockFetch([{ status: 200, body: { ok: true } }]);
    expect(await getJSON("/health")).toEqual({ ok: true });
  });

  test("retries a 503 and returns the next success", async () => {
    const calls = mockFetch([{ status: 503 }, { status: 200, body: { ok: true } }]);
    expect(await getJSON("/health")).toEqual({ ok: true });
    expect(calls.length).toBe(2);
  });

  test("gives up after three attempts", async () => {
    const calls = mockFetch([{ status: 503 }, { status: 503 }, { status: 503 }]);
    await expect(getJSON("/health")).rejects.toMatchObject({ status: 503 });
    expect(calls.length).toBe(3);
  });
});

describe("postJSON", () => {
  test("does not repeat a POST unless asked", async () => {
    const calls = mockFetch([{ status: 503 }, { status: 200, body: {} }]);
    await expect(postJSON("/jobs", { name: "build" })).rejects.toMatchObject({ status: 503 });
    expect(calls.length).toBe(1);
  });
});
`;

const edit = (id: string, path: string, oldText: string, newText: string) => ({
  kind: "tool" as const,
  text: "Edit",
  tool: {
    id,
    title: `Edit ${path.split("/").pop()}`,
    kind: "edit",
    status: "completed",
    diffs: [{ path, oldText, newText, line: 1 }],
  },
});

/// The prompt, the turn's edits and its summary, starting at `at`.
export function workedTurnRows(at: number): AcpmuxRow[] {
  return [
    { id: "worked-user", version: 1, at, kind: "user", text: "Add retries with backoff to the fetch helper" },
    {
      id: "worked-activity",
      version: 1,
      at: at + 4_000,
      kind: "activity",
      toolCount: 3,
      items: [
        edit("worked-retry", "/Users/preview/src/web/src/net/retry.ts", retryBefore, retryAfter),
        edit("worked-client", "/Users/preview/src/web/src/net/client.ts", clientBefore, clientAfter),
        edit("worked-test", "/Users/preview/src/web/src/net/client.test.ts", testBefore, testAfter),
      ],
    },
    {
      id: "worked-summary",
      version: 1,
      at: at + 48_000,
      kind: "assistant",
      text: "GETs now retry 408, 429 and 5xx gateway errors up to three times with jittered exponential backoff. POSTs only retry when the caller passes a policy. Added three tests for the retry paths.",
    },
  ] as AcpmuxRow[];
}
