// acpmux takes the listener token only from a header, never the URL: a URL is written to logs and
// history and sent as a Referer. A browser cannot set an Authorization header on a WebSocket, so the
// direct client offers the token as a subprotocol next to `acpmux.v1`, and its URL carries none.
import { afterAll, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";

const dom = new JSDOM("<!doctype html>", { url: "http://localhost/" });
const scope = globalThis as Record<string, unknown>;
const saved = {
  window: "window" in scope,
  document: "document" in scope,
  values: { window: scope.window, document: scope.document },
};

beforeAll(() => {
  scope.window = dom.window;
  scope.document = dom.window.document;
});
afterAll(() => {
  for (const key of ["window", "document"] as const)
    if (saved[key]) scope[key] = saved.values[key];
    else delete scope[key];
});

test("the direct client sends its token as a subprotocol, never in the URL", async () => {
  const { AcpmuxDirectClient, tokenProtocols } = await import("./direct");
  const { MockAcpmuxSocket, mockHost } = await import("./mock");
  const opened: { url: URL; protocols?: string[] }[] = [];
  const client = await AcpmuxDirectClient.connect(
    { ...mockHost, endpoint: "ws://127.0.0.1:47811/", token: "secret-token-1" },
    () => undefined,
    undefined,
    (url, protocols) => {
      opened.push({ url, protocols });
      return new MockAcpmuxSocket(() => Promise.resolve()) as unknown as WebSocket;
    },
  );
  try {
    expect(opened.length).toBe(1);
    const [{ url, protocols }] = opened;
    expect(url.href).toBe("ws://127.0.0.1:47811/");
    expect(url.href).not.toContain("secret-token-1");
    expect(protocols).toEqual(["acpmux.v1", "acpmux.token.secret-token-1"]);
    expect(tokenProtocols("t")).toEqual(["acpmux.v1", "acpmux.token.t"]);
  } finally {
    client.close();
  }
});

test("a host with no token offers no subprotocol", async () => {
  const { AcpmuxDirectClient } = await import("./direct");
  const { MockAcpmuxSocket, mockHost } = await import("./mock");
  const opened: (string[] | undefined)[] = [];
  const client = await AcpmuxDirectClient.connect(
    { ...mockHost, token: undefined },
    () => undefined,
    undefined,
    (_url, protocols) => {
      opened.push(protocols);
      return new MockAcpmuxSocket(() => Promise.resolve()) as unknown as WebSocket;
    },
  );
  try {
    expect(opened).toEqual([undefined]);
  } finally {
    client.close();
  }
});
