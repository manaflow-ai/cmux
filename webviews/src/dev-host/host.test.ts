import { afterEach, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { devHostParams, devHostReply, installDevHost } from "./host";

const host = {
  endpoint: "ws://127.0.0.1:47901/",
  token: "dev-token",
  cwd: "/repo",
  editorOrigin: "http://127.0.0.1:4200",
};

afterEach(() => {
  delete (globalThis as Record<string, unknown>).window;
  delete (globalThis as Record<string, unknown>).document;
});

test("routes the handshake to the real loopback websocket", () => {
  expect(
    devHostParams("#endpoint=ws://127.0.0.1:47901/&token=abc&cwd=/repo&new&editor=http%3A%2F%2F127.0.0.1%3A4200"),
  ).toEqual({
    endpoint: "ws://127.0.0.1:47901/",
    token: "abc",
    sessionId: undefined,
    newSession: true,
    cwd: "/repo",
    editorOrigin: "http://127.0.0.1:4200",
  });
  expect(devHostReply(host, { id: "1", method: "ready" })).toMatchObject({
    ok: true,
    value: { transport: "acpmux-websocket", endpoint: host.endpoint, token: host.token },
  });
});

test("keeps remote and non-http endpoints out of the dev host", () => {
  expect(devHostParams("#endpoint=ws://example.com:47901/&token=abc")).toBeUndefined();
  expect(devHostParams("#endpoint=wss://127.0.0.1:47901/&token=abc")).toBeUndefined();
  expect(devHostParams("#endpoint=ws://127.0.0.1:47901/&token=abc&editor=https%3A%2F%2Fexample.com")).toBeUndefined();
});

test("routes native file and search calls to safe browser behavior", () => {
  const opened: string[] = [];
  const dom = new JSDOM("<!doctype html>", { url: "http://127.0.0.1:4176/" });
  Object.defineProperty(dom.window, "open", { value: (url: string) => opened.push(url) });
  (globalThis as Record<string, unknown>).window = dom.window;
  (globalThis as Record<string, unknown>).document = dom.window.document;
  expect(devHostReply(host, { id: "2", method: "file.open", params: { path: "/repo/README.md" } })).toMatchObject({
    ok: true,
  });
  expect(opened[0]).toBe("http://127.0.0.1:4200/editor?file=%2Frepo%2FREADME.md");
  expect(devHostReply(host, { id: "3", method: "file.search", params: { query: "readme" } })).toEqual({
    ok: true,
    value: { root: "/repo", search_root: "/repo", results: [], truncated: false },
  });
});

test("installs the page host and only grants a gesture after a DOM event", async () => {
  const dom = new JSDOM("<!doctype html>", { url: "http://127.0.0.1:4176/" });
  (globalThis as Record<string, unknown>).window = dom.window;
  (globalThis as Record<string, unknown>).document = dom.window.document;
  expect(devHostReply(host, { id: "4", method: "transport.gesture" })).toMatchObject({
    ok: false,
    error: { code: "transport.gesture_required" },
  });
  installDevHost(host);
  dom.window.dispatchEvent(new dom.window.Event("pointerdown"));
  expect(devHostReply(host, { id: "5", method: "transport.gesture" })).toMatchObject({ ok: true });
  const page = (dom.window as unknown as { webkit: { messageHandlers: Record<string, unknown> } }).webkit
    .messageHandlers.cmuxPage as { postMessage(message: unknown): Promise<unknown> };
  await expect(page.postMessage({ t: "call", id: 6, op: "cmux.agent.handshake" })).resolves.toMatchObject({
    t: "ok",
    id: 6,
    value: { transport: "acpmux-websocket" },
  });
});

test("browser.open opens only http and https links", () => {
  const opened: string[] = [];
  (globalThis as Record<string, unknown>).window = { open: (url: string) => opened.push(url) };
  for (const url of ["javascript:alert(1)", "data:text/html,x", "file:///etc/passwd", "https://example.test/a"])
    expect(devHostReply(host, { id: "1", method: "browser.open", params: { url } })).toMatchObject({ ok: true });
  expect(opened).toEqual(["https://example.test/a"]);
});
