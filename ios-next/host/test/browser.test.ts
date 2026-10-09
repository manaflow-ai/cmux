import { createServer, type Server } from "node:http";
import type { AddressInfo } from "node:net";
import { afterEach, describe, expect, it } from "vitest";
import { WebSocketServer, type WebSocket } from "ws";
import { decodeBrowserFramePayload } from "../src/rpc/frames.ts";
import { jpegSize, normalizeUrl } from "../src/providers/browser/index.ts";
import { connectedCore, waitFor } from "./helpers.ts";

function fakeJpeg(w: number, h: number): Buffer {
  return Buffer.from([0xff, 0xd8, 0xff, 0xe0, 0x00, 0x04, 0, 0, 0xff, 0xc0, 0x00, 0x11, 0x08, h >> 8, h & 255, w >> 8, w & 255, 3, 1, 0x22, 0, 2, 0x11, 1, 3, 0x11, 1, 0xff, 0xd9]);
}

interface FakeCdp {
  base: string;
  calls: { method: string; params: any; sessionId?: string }[];
  close(): Promise<void>;
}

async function startFakeCdp(): Promise<FakeCdp> {
  const calls: FakeCdp["calls"] = [];
  const http: Server = createServer((req, res) => {
    if (req.url === "/json/version") {
      const port = (http.address() as AddressInfo).port;
      res.setHeader("content-type", "application/json");
      res.end(JSON.stringify({ Browser: "FakeChrome/1", webSocketDebuggerUrl: `ws://127.0.0.1:${port}/devtools/browser/x` }));
    } else {
      res.statusCode = 404;
      res.end();
    }
  });
  const wss = new WebSocketServer({ server: http });
  let frame = 0;
  const sendFrame = (ws: WebSocket) => {
    frame += 1;
    ws.send(
      JSON.stringify({
        method: "Page.screencastFrame",
        sessionId: "S1",
        params: { data: fakeJpeg(1170, 2532).toString("base64"), metadata: { deviceWidth: 390, deviceHeight: 844 }, sessionId: 100 + frame },
      }),
    );
  };
  wss.on("connection", (ws) => {
    ws.on("message", (raw) => {
      const msg = JSON.parse(raw.toString());
      calls.push({ method: msg.method, params: msg.params, sessionId: msg.sessionId });
      const reply = (result: unknown) => ws.send(JSON.stringify({ id: msg.id, result, ...(msg.sessionId ? { sessionId: msg.sessionId } : {}) }));
      switch (msg.method) {
        case "Target.getTargets":
          return reply({ targetInfos: [{ targetId: "T1", type: "page", url: "https://example.com/", title: "Example" }, { targetId: "W1", type: "service_worker", url: "x", title: "" }] });
        case "Target.attachToTarget":
          return reply({ sessionId: "S1" });
        case "Page.getNavigationHistory":
          return reply({ currentIndex: 1, entries: [{ id: 1 }, { id: 2 }] });
        case "Runtime.evaluate":
          return reply({ result: { value: { icon: "https://example.com/favicon.ico", title: "Example Domain" } } });
        case "Page.captureScreenshot":
          return reply({ data: fakeJpeg(10, 10).toString("base64") });
        case "Target.createTarget":
          reply({ targetId: "T2" });
          ws.send(JSON.stringify({ method: "Target.targetCreated", params: { targetInfo: { targetId: "T2", type: "page", url: "https://new.example/", title: "" } } }));
          return;
        case "Page.startScreencast":
          frame = 0;
          reply({});
          return sendFrame(ws);
        case "Page.screencastFrameAck":
          reply({});
          if (frame < 3) sendFrame(ws);
          return;
        default:
          return reply({});
      }
    });
  });
  await new Promise<void>((r) => http.listen(0, "127.0.0.1", r));
  const base = `http://127.0.0.1:${(http.address() as AddressInfo).port}`;
  return {
    base,
    calls,
    close: () =>
      new Promise((r) => {
        for (const c of wss.clients) c.terminate();
        wss.close();
        http.close(() => r());
      }),
  };
}

const cleanups: (() => unknown)[] = [];
afterEach(async () => {
  for (const f of cleanups.splice(0)) await f();
});

describe("browser helpers", () => {
  it("normalizes urls and reads jpeg sizes", () => {
    expect(normalizeUrl("example.com")).toBe("https://example.com");
    expect(normalizeUrl("localhost:3000/x")).toBe("http://localhost:3000/x");
    expect(normalizeUrl("https://a.b/c")).toBe("https://a.b/c");
    expect(normalizeUrl("how are you")).toBe("https://www.google.com/search?q=how%20are%20you");
    expect(jpegSize(fakeJpeg(1170, 2532))).toEqual({ width: 1170, height: 2532 });
  });
});

describe("BrowserProvider with a fake CDP endpoint", () => {
  it("lists tabs, screencasts with ack flow control, and dispatches input", async () => {
    const cdp = await startFakeCdp();
    cleanups.push(() => cdp.close());
    const { core, client } = await connectedCore({ browser: { cdp: cdp.base, launch: false } });
    cleanups.push(() => core.shutdown());
    const hello = await client.hello();
    expect(hello.capabilities).toContain("browser.v1");

    const { tabs } = await client.request("browser.list");
    expect(tabs).toEqual([expect.objectContaining({ id: "T1", url: "https://example.com/", title: "Example", active: true })]);
    const tabEvents: any[] = [];
    client.peer.on("event", (t, p) => t === "browser.tab" && tabEvents.push(p.tab));
    await waitFor(() => tabEvents.find((t) => t.canGoBack && t.faviconUrl));

    const { streamId, tab } = await client.request("browser.attach", { tabId: "T1", width: 390, height: 844, scale: 3, mobile: true });
    expect(tab.id).toBe("T1");
    const frames: ReturnType<typeof decodeBrowserFramePayload>[] = [];
    client.onStream(streamId, (p) => frames.push(decodeBrowserFramePayload(Uint8Array.from(p))));
    const metrics = cdp.calls.find((c) => c.method === "Emulation.setDeviceMetricsOverride")!;
    expect(metrics).toMatchObject({ sessionId: "S1", params: { width: 390, height: 844, deviceScaleFactor: 3, mobile: true } });
    expect(cdp.calls.find((c) => c.method === "Page.startScreencast")!.params).toMatchObject({ format: "jpeg", quality: 70, maxWidth: 1170, maxHeight: 2532 });

    // Two frames arrive; the second CDP ack is held until the phone acks.
    await waitFor(() => frames.length === 2);
    await new Promise((r) => setTimeout(r, 50));
    expect(frames.length).toBe(2);
    expect(frames[0]!.header).toEqual({ seq: 1, cssW: 390, cssH: 844, pxW: 1170, pxH: 2532, format: 0 });
    expect(cdp.calls.filter((c) => c.method === "Page.screencastFrameAck").map((c) => c.params.sessionId)).toEqual([101]);
    await client.request("browser.ack", { streamId, seq: 1 });
    await waitFor(() => frames.length === 3);
    expect(cdp.calls.filter((c) => c.method === "Page.screencastFrameAck").map((c) => c.params.sessionId)).toEqual([101, 102]);

    await client.request("browser.touch", { tabId: "T1", type: "start", points: [{ x: 10, y: 20, id: 0 }] });
    await client.request("browser.pointer", { tabId: "T1", type: "down", x: 5, y: 6, button: "left", clickCount: 1 });
    await client.request("browser.scroll", { tabId: "T1", x: 1, y: 2, dx: 0, dy: 120 });
    await client.request("browser.key", { tabId: "T1", type: "down", key: "Enter", code: "Enter", text: "\r", modifiers: 0 });
    await client.request("browser.text", { tabId: "T1", text: "hello" });
    await client.request("browser.navigate", { tabId: "T1", url: "example.org" });
    await client.request("browser.back", { tabId: "T1" });
    const by = (m: string) => cdp.calls.filter((c) => c.method === m).map((c) => c.params);
    expect(by("Input.dispatchTouchEvent")).toEqual([{ type: "touchStart", touchPoints: [{ x: 10, y: 20, id: 0 }] }]);
    expect(by("Input.dispatchMouseEvent")).toEqual([
      expect.objectContaining({ type: "mousePressed", x: 5, y: 6, button: "left", clickCount: 1 }),
      expect.objectContaining({ type: "mouseWheel", deltaY: 120 }),
    ]);
    expect(by("Input.dispatchKeyEvent")[0]).toMatchObject({ type: "keyDown", key: "Enter", text: "\r", windowsVirtualKeyCode: 13 });
    expect(by("Input.insertText")).toEqual([{ text: "hello" }]);
    expect(by("Page.navigate")).toEqual([{ url: "https://example.org" }]);
    expect(by("Page.navigateToHistoryEntry")).toEqual([{ entryId: 1 }]);
    const shot = await client.request("browser.screenshot", { tabId: "T1" });
    expect(typeof shot.dataBase64).toBe("string");

    await client.request("browser.detach", { streamId });
    await waitFor(() => cdp.calls.some((c) => c.method === "Emulation.clearDeviceMetricsOverride"));
    expect(cdp.calls.some((c) => c.method === "Page.stopScreencast")).toBe(true);

    const created = await client.request("browser.create", { url: "new.example" });
    expect(created.tab).toMatchObject({ id: "T2", active: true });
  });

  it("reports browser.v1 absent when no browser exists", async () => {
    const { core, client } = await connectedCore();
    cleanups.push(() => core.shutdown());
    const hello = await client.hello();
    expect(hello.capabilities).not.toContain("browser.v1");
  });
});
