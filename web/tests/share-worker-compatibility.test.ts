import { describe, expect, test } from "bun:test";

import {
  requireCompatibleShareWorker,
  SHARE_PROTOCOL_VERSION,
  SHARE_TERMINAL_TRANSPORT_VERSION,
  shareWorkerHealthUrl,
  shareWorkerWebSocketBaseUrl,
} from "../services/share/compatibility";

const VALID_HEALTH = {
  ok: true,
  service: "cmux-share",
  protocolVersion: SHARE_PROTOCOL_VERSION,
  terminalTransportVersion: SHARE_TERMINAL_TRANSPORT_VERSION,
  deploymentId: "deployment-live-123",
};

function jsonResponse(value: unknown, init?: ResponseInit): Response {
  return new Response(JSON.stringify(value), {
    status: 200,
    headers: { "content-type": "application/json" },
    ...init,
  });
}

describe("share Worker compatibility", () => {
  test("derives private health and public WebSocket URLs for local ws/http bases", () => {
    expect(shareWorkerHealthUrl("ws://127.0.0.1:8787/")).toBe(
      "http://127.0.0.1:8787/healthz",
    );
    expect(shareWorkerWebSocketBaseUrl("http://127.0.0.1:8787/")).toBe(
      "ws://127.0.0.1:8787",
    );
    expect(shareWorkerHealthUrl("wss://share.example.com")).toBe(
      "https://share.example.com/healthz",
    );
    expect(shareWorkerWebSocketBaseUrl("https://share.example.com")).toBe(
      "wss://share.example.com",
    );
  });

  test("fetches once inside the short cache window without forwarding credentials", async () => {
    const requests: Array<{ url: string; init: RequestInit | undefined }> = [];
    const fetcher = (async (
      input: string | URL | Request,
      init?: RequestInit,
    ) => {
      requests.push({ url: String(input), init });
      return jsonResponse(VALID_HEALTH);
    }) as typeof fetch;
    let now = 1_000;
    const options = {
      baseUrl: "wss://cache-test.example.com",
      fetch: fetcher,
      nowMs: () => now,
      cacheTtlMs: 5_000,
    };

    const first = await requireCompatibleShareWorker(options);
    now += 4_999;
    const second = await requireCompatibleShareWorker(options);
    now += 1;
    const afterExpiry = await requireCompatibleShareWorker(options);

    expect(first).toEqual({
      protocolVersion: 2,
      terminalTransportVersion: 1,
      deploymentId: "deployment-live-123",
    });
    expect(second).toEqual(first);
    expect(afterExpiry).toEqual(first);
    expect(requests).toHaveLength(2);
    expect(requests[0]?.url).toBe(
      "https://cache-test.example.com/healthz",
    );
    expect(requests[0]?.url).not.toContain("token");
    expect(requests[0]?.init).toMatchObject({
      method: "GET",
      cache: "no-store",
      redirect: "error",
      headers: { accept: "application/json" },
    });
  });

  test("rejects stale and mismatched Worker health contracts", async () => {
    const incompatibleBodies: unknown[] = [
      { ok: true, service: "cmux-share" },
      { ...VALID_HEALTH, protocolVersion: 1 },
      { ...VALID_HEALTH, terminalTransportVersion: 2 },
      { ...VALID_HEALTH, deploymentId: "" },
      { ...VALID_HEALTH, service: "other" },
    ];

    for (const [index, body] of incompatibleBodies.entries()) {
      await expect(
        requireCompatibleShareWorker({
          baseUrl: `wss://incompatible-${index}.example.com`,
          fetch: (async () => jsonResponse(body)) as typeof fetch,
        }),
      ).rejects.toMatchObject({
        _tag: "ShareWorkerCompatibilityError",
        code: "share_worker_incompatible",
      });
    }
  });

  test("rejects unreachable or non-successful Workers as unavailable", async () => {
    await expect(
      requireCompatibleShareWorker({
        baseUrl: "wss://unreachable.example.com",
        fetch: (async () => {
          throw new TypeError("connect failed");
        }) as typeof fetch,
      }),
    ).rejects.toMatchObject({
      _tag: "ShareWorkerCompatibilityError",
      code: "share_worker_unavailable",
    });

    await expect(
      requireCompatibleShareWorker({
        baseUrl: "wss://status.example.com",
        fetch: (async () =>
          jsonResponse({ error: "not_found" }, { status: 404 })) as typeof fetch,
      }),
    ).rejects.toMatchObject({
      _tag: "ShareWorkerCompatibilityError",
      code: "share_worker_unavailable",
    });
  });

  test("aborts a hanging Worker within the configured timeout", async () => {
    const observed: { signal?: AbortSignal } = {};
    const hangingFetch = ((
      _input: string | URL | Request,
      init?: RequestInit,
    ) =>
      new Promise<Response>((_resolve, reject) => {
        observed.signal = init?.signal as AbortSignal;
        observed.signal.addEventListener(
          "abort",
          () => reject(observed.signal?.reason),
          { once: true },
        );
      })) as typeof fetch;

    await expect(
      requireCompatibleShareWorker({
        baseUrl: "ws://127.0.0.1:65530",
        fetch: hangingFetch,
        timeoutMs: 10,
      }),
    ).rejects.toMatchObject({
      _tag: "ShareWorkerCompatibilityError",
      code: "share_worker_unavailable",
    });
    expect(observed.signal?.aborted).toBe(true);
  });

  test("rejects base URLs that could leak credentials to health checks", async () => {
    let fetched = false;
    await expect(
      requireCompatibleShareWorker({
        baseUrl: "wss://share.example.com?token=secret",
        fetch: (async () => {
          fetched = true;
          return jsonResponse(VALID_HEALTH);
        }) as typeof fetch,
      }),
    ).rejects.toMatchObject({
      _tag: "ShareWorkerCompatibilityError",
      code: "share_worker_unavailable",
    });
    expect(fetched).toBe(false);
  });
});
