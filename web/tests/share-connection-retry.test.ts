import { afterEach, beforeEach, describe, expect, test } from "bun:test";

import { ShareClient } from "../app/[locale]/share/[code]/share-connection";

const originalFetch = globalThis.fetch;
const originalWebSocket = globalThis.WebSocket;
const originalSetTimeout = globalThis.setTimeout;
const originalClearTimeout = globalThis.clearTimeout;

type ScheduledTimer = {
  readonly callback: (...args: unknown[]) => void;
  readonly delay: number;
  readonly args: readonly unknown[];
};

const scheduledTimers = new Map<number, ScheduledTimer>();
const clients = new Set<ShareClient>();
let nextTimerId = 1;

class FakeWebSocket {
  static readonly CONNECTING = 0;
  static readonly OPEN = 1;
  static readonly CLOSING = 2;
  static readonly CLOSED = 3;
  static instances: FakeWebSocket[] = [];

  readonly url: string;
  readyState = FakeWebSocket.CONNECTING;
  binaryType: BinaryType = "blob";
  onopen: ((event: Event) => void) | null = null;
  onmessage: ((event: MessageEvent) => void) | null = null;
  onclose: ((event: CloseEvent) => void) | null = null;
  sent: string[] = [];

  constructor(url: string | URL) {
    this.url = String(url);
    FakeWebSocket.instances.push(this);
  }

  send(data: string): void {
    this.sent.push(data);
  }

  close(code = 1000, reason = ""): void {
    if (this.readyState === FakeWebSocket.CLOSED) return;
    this.readyState = FakeWebSocket.CLOSED;
    this.onclose?.({ code, reason } as CloseEvent);
  }

  receive(message: unknown): void {
    this.onmessage?.({ data: JSON.stringify(message) } as MessageEvent);
  }

  serverClose(code: number): void {
    this.close(code, "server-close");
  }
}

beforeEach(() => {
  scheduledTimers.clear();
  clients.clear();
  nextTimerId = 1;
  FakeWebSocket.instances = [];
  globalThis.WebSocket = FakeWebSocket as unknown as typeof WebSocket;
  globalThis.setTimeout = ((
    callback: (...args: unknown[]) => void,
    delay?: number,
    ...args: unknown[]
  ) => {
    const id = nextTimerId;
    nextTimerId += 1;
    scheduledTimers.set(id, {
      callback,
      delay: Number(delay ?? 0),
      args,
    });
    return id as unknown as ReturnType<typeof setTimeout>;
  }) as unknown as typeof setTimeout;
  globalThis.clearTimeout = ((id: ReturnType<typeof setTimeout> | undefined) => {
    scheduledTimers.delete(id as unknown as number);
  }) as typeof clearTimeout;
});

afterEach(() => {
  for (const client of clients) client.stop();
  clients.clear();
  globalThis.fetch = originalFetch;
  globalThis.WebSocket = originalWebSocket;
  globalThis.setTimeout = originalSetTimeout;
  globalThis.clearTimeout = originalClearTimeout;
});

function clientWithActiveSession(): ShareClient {
  const client = new ShareClient("code12345678");
  client.session.update({ status: "active", reconnecting: false });
  clients.add(client);
  return client;
}

function tokenError(
  status: number,
  error: string,
  headers: HeadersInit = {},
): Response {
  return new Response(JSON.stringify({ error }), {
    status,
    headers: {
      "content-type": "application/json",
      ...headers,
    },
  });
}

function retryDelays(): number[] {
  return [...scheduledTimers.values()].map((timer) => timer.delay);
}

async function settle(): Promise<void> {
  for (let turn = 0; turn < 8; turn += 1) {
    await Promise.resolve();
  }
}

async function runOnlyTimer(): Promise<void> {
  const entries = [...scheduledTimers.entries()];
  expect(entries).toHaveLength(1);
  const [id, timer] = entries[0] as [number, ScheduledTimer];
  scheduledTimers.delete(id);
  timer.callback(...timer.args);
  await settle();
}

function pendingResponse(): Promise<Response> {
  return new Promise<Response>(() => {});
}

describe("ShareClient token refresh failures", () => {
  test("retries a transient network error without discarding the active session", async () => {
    let fetchCalls = 0;
    globalThis.fetch = (async () => {
      fetchCalls += 1;
      if (fetchCalls === 1) throw new TypeError("network unavailable");
      return pendingResponse();
    }) as typeof fetch;
    const client = clientWithActiveSession();

    client.start();
    await settle();

    expect(client.session.get().status).toBe("active");
    expect(client.session.get().reconnecting).toBe(true);
    expect(retryDelays()).toEqual([800]);

    await runOnlyTimer();
    expect(fetchCalls).toBe(2);
  });

  for (const retry of [
    { header: "0", delay: 1_000, name: "the one-second minimum" },
    { header: "4", delay: 4_000, name: "the server delay" },
    { header: "7200", delay: 3_600_000, name: "the one-hour maximum" },
  ]) {
    test(`clamps HTTP 429 Retry-After to ${retry.name}`, async () => {
      let fetchCalls = 0;
      globalThis.fetch = (async () => {
        fetchCalls += 1;
        if (fetchCalls === 1) {
          return tokenError(429, "rate_limited", {
            "retry-after": retry.header,
          });
        }
        return pendingResponse();
      }) as typeof fetch;
      const client = clientWithActiveSession();

      client.start();
      await settle();

      expect(client.session.get().status).toBe("active");
      expect(client.session.get().reconnecting).toBe(true);
      expect(retryDelays()).toEqual([retry.delay]);

      await runOnlyTimer();
      expect(fetchCalls).toBe(2);
    });
  }

  for (const status of [500, 502, 503, 504]) {
    test(`retries HTTP ${status} without replacing the active session`, async () => {
      let fetchCalls = 0;
      globalThis.fetch = (async () => {
        fetchCalls += 1;
        if (fetchCalls === 1) {
          return tokenError(status, "temporary_upstream_failure");
        }
        return pendingResponse();
      }) as typeof fetch;
      const client = clientWithActiveSession();

      client.start();
      await settle();

      expect(client.session.get().status).toBe("active");
      expect(client.session.get().reconnecting).toBe(true);
      expect(retryDelays()).toEqual([800]);

      await runOnlyTimer();
      expect(fetchCalls).toBe(2);
    });
  }

  test("retries a non-JSON HTTP 503 instead of treating it as configuration failure", async () => {
    let fetchCalls = 0;
    globalThis.fetch = (async () => {
      fetchCalls += 1;
      if (fetchCalls === 1) {
        return new Response("<html>temporary gateway failure</html>", {
          status: 503,
          headers: { "content-type": "text/html" },
        });
      }
      return pendingResponse();
    }) as typeof fetch;
    const client = clientWithActiveSession();

    client.start();
    await settle();

    expect(client.session.get().status).toBe("active");
    expect(client.session.get().reconnecting).toBe(true);
    expect(retryDelays()).toEqual([800]);

    await runOnlyTimer();
    expect(fetchCalls).toBe(2);
  });

  for (const failure of [
    { name: "invalid code", status: 400, error: "invalid_code" },
    { name: "unauthorized auth", status: 401, error: "unauthorized" },
    {
      name: "missing share configuration",
      status: 503,
      error: "share_not_configured",
    },
  ]) {
    test(`keeps ${failure.name} failures terminal`, async () => {
      let fetchCalls = 0;
      globalThis.fetch = (async () => {
        fetchCalls += 1;
        return tokenError(failure.status, failure.error);
      }) as typeof fetch;
      const client = clientWithActiveSession();

      client.start();
      await settle();

      expect(fetchCalls).toBe(1);
      expect(client.session.get().status).toBe("unavailable");
      expect(client.session.get().reconnecting).toBe(false);
      expect(retryDelays()).toEqual([]);
    });
  }
});

describe("ShareClient terminal server states", () => {
  for (const terminal of [
    {
      name: "denial",
      message: { t: "access-denied" },
      status: "denied",
    },
    {
      name: "kick",
      message: { t: "kicked" },
      status: "kicked",
    },
    {
      name: "session end",
      message: { t: "session-ended", reason: "host-stopped" },
      status: "ended",
    },
  ] as const) {
    test(`does not reconnect after ${terminal.name}`, async () => {
      globalThis.fetch = (async () =>
        new Response(
          JSON.stringify({
            token: "guest-token",
            wsUrl: "wss://share.cmux.test/v1/share/sessions/code12345678/ws",
          }),
          {
            status: 200,
            headers: { "content-type": "application/json" },
          },
        )) as typeof fetch;
      const client = clientWithActiveSession();

      client.start();
      await settle();
      const socket = FakeWebSocket.instances[0];
      expect(socket).toBeDefined();

      socket?.receive(terminal.message);
      socket?.serverClose(1006);

      expect(client.session.get().status).toBe(terminal.status);
      expect(client.session.get().reconnecting).toBe(false);
      expect(retryDelays()).toEqual([]);
    });
  }
});
