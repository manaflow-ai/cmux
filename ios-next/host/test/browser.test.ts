import { createServer, type Server } from "node:http";
import type { AddressInfo } from "node:net";
import { afterEach, describe, expect, it } from "vitest";
import { WebSocketServer, type WebSocket } from "ws";
import { decodeBrowserFramePayload } from "../src/rpc/frames.ts";
import {
  IPHONE_USER_AGENT,
  MAX_UNACKED,
  QUALITY_IDLE,
  QUALITY_INTERACTIVE,
  decodeBrowserFrameMeta,
  jpegSize,
  normalizeUrl,
} from "../src/providers/browser/index.ts";
import { mkdtempSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { HostClient } from "../src/client.ts";
import { spawn } from "node:child_process";
import { ownEndpoint, profileChromeProcesses, retireUnsafeProfileChrome } from "../src/providers/browser/chrome.ts";
import { createOpenLoopbackPair } from "../src/transport/loopback.ts";
import { connectedCore, waitFor } from "./helpers.ts";

function fakeJpeg(w: number, h: number): Buffer {
  return Buffer.from([0xff, 0xd8, 0xff, 0xe0, 0x00, 0x04, 0, 0, 0xff, 0xc0, 0x00, 0x11, 0x08, h >> 8, h & 255, w >> 8, w & 255, 3, 1, 0x22, 0, 2, 0x11, 1, 3, 0x11, 1, 0xff, 0xd9]);
}

interface FakeCdp {
  base: string;
  /** document.visibilityState the fake page reports. */
  state: { hidden: boolean };
  calls: { method: string; params: any; sessionId?: string }[];
  close(): Promise<void>;
}

async function startFakeCdp(): Promise<FakeCdp> {
  const calls: FakeCdp["calls"] = [];
  const state = { hidden: false };
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
          if (msg.params.expression === "document.visibilityState") return reply({ result: { value: state.hidden ? "hidden" : "visible" } });
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
          if (frame < 6) sendFrame(ws);
          return;
        case "Target.closeTarget":
          return reply({ success: msg.params.targetId !== "GONE" });
        default:
          return reply({});
      }
    });
  });
  await new Promise<void>((r) => http.listen(0, "127.0.0.1", r));
  const base = `http://127.0.0.1:${(http.address() as AddressInfo).port}`;
  return {
    base,
    state,
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
    expect(cdp.calls.find((c) => c.method === "Page.startScreencast")!.params).toMatchObject({ format: "jpeg", quality: QUALITY_IDLE, maxWidth: 1170, maxHeight: 2532 });
    // mobile:true also sets the iPhone user agent.
    expect(cdp.calls.find((c) => c.method === "Emulation.setUserAgentOverride")!.params).toMatchObject({ userAgent: IPHONE_USER_AGENT, platform: "iPhone" });

    // MAX_UNACKED frames arrive; the last CDP ack is held until the phone acks.
    await waitFor(() => frames.length === MAX_UNACKED);
    await new Promise((r) => setTimeout(r, 50));
    expect(frames.length).toBe(MAX_UNACKED);
    expect(frames[0]!.header).toEqual({ seq: 1, cssW: 390, cssH: 844, pxW: 1170, pxH: 2532, format: 0 });
    const acks = () => cdp.calls.filter((c) => c.method === "Page.screencastFrameAck").map((c) => c.params.sessionId);
    expect(acks()).toEqual([101, 102, 103]);
    await client.request("browser.ack", { streamId, seq: 1 });
    await waitFor(() => frames.length === MAX_UNACKED + 1);
    expect(acks()).toEqual([101, 102, 103, 104]);

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

  it("sends scroll metadata on request, lowers JPEG quality while touching and closes tabs it lost track of", async () => {
    const cdp = await startFakeCdp();
    cleanups.push(() => cdp.close());
    const { core, client } = await connectedCore({ browser: { cdp: cdp.base, launch: false } });
    cleanups.push(() => core.shutdown());
    await client.request("browser.list");
    const { streamId } = await client.request("browser.attach", { tabId: "T1", width: 390, height: 844, scale: 3, mobile: true, frameMeta: true });
    const payloads: Uint8Array[] = [];
    client.onStream(streamId, (p) => payloads.push(Uint8Array.from(p)));
    expect(cdp.calls.some((c) => c.method === "Runtime.addBinding" && c.params.name === "__cmuxNextScroll")).toBe(true);
    await waitFor(() => payloads.length >= 1);
    expect(decodeBrowserFrameMeta(payloads[0]!)).toEqual({ scrollX: 0, scrollY: 0, pageScale: 1, offsetTop: 0 });

    // A tab that went to the background is brought back before input.
    cdp.state.hidden = true;
    const fronts = () => cdp.calls.filter((c) => c.method === "Page.bringToFront").length;
    const before = fronts();
    await client.request("browser.touch", { tabId: "T1", type: "start", points: [{ x: 10, y: 20, id: 0 }] });
    expect(fronts()).toBe(before + 1);
    cdp.state.hidden = false;
    await waitFor(() => cdp.calls.some((c) => c.method === "Page.startScreencast" && c.params.quality === QUALITY_INTERACTIVE));
    await waitFor(() => cdp.calls.filter((c) => c.method === "Page.startScreencast").at(-1)!.params.quality === QUALITY_IDLE, 3_000);

    // Desktop mode restores the browser's own user agent.
    await client.request("browser.detach", { streamId });
    await client.request("browser.attach", { tabId: "T1", width: 980, height: 1980, scale: 1.2, mobile: false });
    const metrics = cdp.calls.filter((c) => c.method === "Emulation.setDeviceMetricsOverride").at(-1)!;
    expect(metrics.params).toMatchObject({ width: 980, mobile: false });

    await client.request("browser.close", { tabId: "T1" });
    expect(cdp.calls.filter((c) => c.method === "Target.closeTarget").at(-1)!.params).toEqual({ targetId: "T1" });
    // A target the host no longer tracks is still closed in Chrome.
    await client.request("browser.close", { tabId: "UNTRACKED" });
    await expect(client.request("browser.close", { tabId: "GONE" })).rejects.toMatchObject({ code: "not_found" });
  });

  it("stops the old screencast before a new attachment takes over and tells the displaced client", async () => {
    const cdp = await startFakeCdp();
    cleanups.push(() => cdp.close());
    const { core, client } = await connectedCore({ browser: { cdp: cdp.base, launch: false } });
    cleanups.push(() => core.shutdown());
    const [phone2, host2] = createOpenLoopbackPair();
    core.attach(host2);
    const client2 = new HostClient(phone2);
    await client2.hello("second");
    const events: any[] = [];
    client.peer.on("event", (t, p) => t === "browser.detached" && events.push(p));
    const first = await client.request("browser.attach", { tabId: "T1", width: 390, height: 844, scale: 3, mobile: true });
    await client2.request("browser.attach", { tabId: "T1", width: 400, height: 800, scale: 2, mobile: true });
    await waitFor(() => events.length === 1);
    expect(events[0]).toEqual({ streamId: first.streamId, tabId: "T1", reason: "displaced" });
    const order = cdp.calls.map((c) => c.method).filter((m) => m === "Page.startScreencast" || m === "Page.stopScreencast");
    expect(order).toEqual(["Page.startScreencast", "Page.stopScreencast", "Page.startScreencast"]);
    await expect(client.request("browser.ack", { streamId: first.streamId, seq: 1 })).rejects.toMatchObject({ code: "not_found" });
  });

  it("serializes concurrent attaches and makes detach wait for the screencast to stop", async () => {
    const cdp = await startFakeCdp();
    cleanups.push(() => cdp.close());
    const { core, client } = await connectedCore({ browser: { cdp: cdp.base, launch: false } });
    cleanups.push(() => core.shutdown());
    const [phone2, host2] = createOpenLoopbackPair();
    core.attach(host2);
    const client2 = new HostClient(phone2);
    await client2.hello("second");
    const detached: any[] = [];
    for (const c of [client, client2]) c.peer.on("event", (t, p) => t === "browser.detached" && detached.push(p));
    await client.request("browser.list");
    const [r1, r2] = await Promise.all([
      client.request("browser.attach", { tabId: "T1", width: 390, height: 844, scale: 3, mobile: true }),
      client2.request("browser.attach", { tabId: "T1", width: 400, height: 800, scale: 2, mobile: true }),
    ]);
    await waitFor(() => detached.length === 1);
    expect(detached[0]).toEqual({ streamId: r1.streamId, tabId: "T1", reason: "displaced" });
    const casts = () => cdp.calls.map((c) => c.method).filter((m) => m === "Page.startScreencast" || m === "Page.stopScreencast");
    expect(casts()).toEqual(["Page.startScreencast", "Page.stopScreencast", "Page.startScreencast"]);
    await client2.request("browser.detach", { streamId: r2.streamId });
    // detach resolved only after the screencast stopped and the viewport was restored
    expect(casts().at(-1)).toBe("Page.stopScreencast");
    expect(cdp.calls.at(-1)!.method).toBe("Emulation.setTouchEmulationEnabled");
    expect(cdp.calls.some((c) => c.method === "Emulation.clearDeviceMetricsOverride")).toBe(true);
  });

  it("stops a profile browser an older host launched with --remote-allow-origins", async () => {
    const profile = mkdtempSync(join(tmpdir(), "cnh-profile-"));
    const spawnFake = (extra: string[]) =>
      spawn(process.execPath, ["-e", "setInterval(() => {}, 1000)", "--", `--user-data-dir=${profile}`, ...extra], { stdio: "ignore" });
    const safe = spawnFake(["--remote-debugging-port=0"]);
    await waitFor(async () => (await profileChromeProcesses(profile)).length === 1);
    expect(await retireUnsafeProfileChrome(() => {}, profile)).toBe(false);
    expect(safe.exitCode).toBeNull();
    safe.kill();
    await new Promise((r) => safe.once("exit", r));
    const unsafe = spawnFake(["--remote-debugging-port=9222", "--remote-allow-origins=*"]);
    await waitFor(async () => (await profileChromeProcesses(profile)).length === 1);
    const exited = new Promise((r) => unsafe.once("exit", r));
    expect(await retireUnsafeProfileChrome(() => {}, profile)).toBe(true);
    await exited;
  });

  it("only adopts a CDP endpoint the host launched (DevToolsActivePort in its profile)", async () => {
    const cdp = await startFakeCdp();
    cleanups.push(() => cdp.close());
    const profile = mkdtempSync(join(tmpdir(), "cnh-profile-"));
    expect(await ownEndpoint(profile)).toBeNull();
    writeFileSync(join(profile, "DevToolsActivePort"), `${new URL(cdp.base).port}\n/devtools/browser/x\n`);
    expect(await ownEndpoint(profile)).toBe(cdp.base);
    writeFileSync(join(profile, "DevToolsActivePort"), "1\n/devtools/browser/x\n");
    expect(await ownEndpoint(profile)).toBeNull();
  });

  it("reports browser.v1 absent when no browser exists", async () => {
    const { core, client } = await connectedCore();
    cleanups.push(() => core.shutdown());
    const hello = await client.hello();
    expect(hello.capabilities).not.toContain("browser.v1");
  });
});
