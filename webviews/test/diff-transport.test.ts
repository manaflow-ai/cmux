import { afterEach, expect, test } from "bun:test";
import type { DiffRequest, DiffResponse } from "../src/diff/generated/protocol";
import {
  FetchDiffTransport,
  WebKitDiffTransport,
  supportsFetchTransport,
} from "../src/diff/transport";

const originalWindow = globalThis.window;
const originalFetch = globalThis.fetch;

afterEach(() => {
  globalThis.fetch = originalFetch;
  if (originalWindow === undefined) {
    delete (globalThis as { window?: Window }).window;
  } else {
    globalThis.window = originalWindow;
  }
});

test("fetch and WebKit transports use the same generated request envelope", async () => {
  let fetchRequest: DiffRequest | null = null;
  let webKitRequest: DiffRequest | null = null;
  const response: DiffResponse = {
    id: "response",
    version: 1,
    result: { type: "handshake", value: { protocolVersion: 1, capabilities: [] } },
    error: null,
  };
  globalThis.window = { webkit: { messageHandlers: {} } } as Window & typeof globalThis;
  globalThis.fetch = (async (_input, init) => {
    fetchRequest = JSON.parse(String(init?.body)) as DiffRequest;
    return Response.json({ ...response, id: fetchRequest.id });
  }) as typeof fetch;
  const fetchTransport = new FetchDiffTransport("/__cmux_diff_rpc", 1);
  await fetchTransport.request({ method: "protocolHandshake" });

  const webKitTransport = new WebKitDiffTransport({
    async postMessage(message) {
      webKitRequest = message as DiffRequest;
      return { ...response, id: webKitRequest.id };
    },
  }, 1);
  await webKitTransport.request({ method: "protocolHandshake" });

  const capturedFetchRequest = fetchRequest as DiffRequest | null;
  const capturedWebKitRequest = webKitRequest as DiffRequest | null;
  expect(capturedFetchRequest?.version).toBe(1);
  expect(capturedFetchRequest?.method).toBe("protocolHandshake");
  expect(capturedWebKitRequest?.version).toBe(1);
  expect(capturedWebKitRequest?.method).toBe("protocolHandshake");
});

test("fetch transport is disabled when a persisted viewer is restored through the custom scheme", () => {
  expect(supportsFetchTransport("http:")).toBe(true);
  expect(supportsFetchTransport("https:")).toBe(true);
  expect(supportsFetchTransport("cmux-diff-viewer:")).toBe(false);
});
