// The Mac's browser tabs over CEF DevTools (opt-in setting file), against a
// fake devtools.json and a fake CDP endpoint.
import { chmodSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { createServer, type Server } from "node:http";
import type { AddressInfo } from "node:net";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, describe, expect, it } from "vitest";
import { WebSocketServer } from "ws";
import { MacBrowser, matchTargets } from "../src/bridge/macBrowser.ts";
import { mapDaemonLayout } from "../src/layout/index.ts";
import { connectedCore, waitFor } from "./helpers.ts";

const cleanups: (() => unknown)[] = [];
afterEach(async () => {
  for (const f of cleanups.splice(0)) await f();
});

async function fakeCef() {
  const calls: { method: string; params: any; sessionId?: string }[] = [];
  const http: Server = createServer((req, res) => {
    if (req.url === "/json/version") {
      const port = (http.address() as AddressInfo).port;
      res.setHeader("content-type", "application/json");
      res.end(JSON.stringify({ Browser: "CEF/1", "User-Agent": "Mozilla/5.0 Mac", webSocketDebuggerUrl: `ws://127.0.0.1:${port}/devtools/browser/x` }));
    } else {
      res.statusCode = 404;
      res.end();
    }
  });
  const wss = new WebSocketServer({ server: http });
  wss.on("connection", (ws) => {
    ws.on("message", (raw) => {
      const msg = JSON.parse(raw.toString());
      calls.push({ method: msg.method, params: msg.params, sessionId: msg.sessionId });
      const reply = (result: unknown) => ws.send(JSON.stringify({ id: msg.id, result, ...(msg.sessionId ? { sessionId: msg.sessionId } : {}) }));
      switch (msg.method) {
        case "Target.getTargets":
          return reply({
            targetInfos: [
              { targetId: "CEF1", type: "page", url: "https://example.com/", title: "Example" },
              { targetId: "CEF2", type: "page", url: "https://news.example/", title: "News" },
            ],
          });
        case "Target.attachToTarget":
          return reply({ sessionId: `S-${msg.params.targetId}` });
        case "Page.getNavigationHistory":
          return reply({ currentIndex: 0, entries: [{ id: 1 }] });
        case "Runtime.evaluate":
          return reply({ result: { value: { title: "Example" } } });
        default:
          return reply({});
      }
    });
  });
  await new Promise<void>((r) => http.listen(0, "127.0.0.1", r));
  const port = (http.address() as AddressInfo).port;
  return {
    port,
    calls,
    close: () =>
      new Promise<void>((r) => {
        for (const c of wss.clients) c.terminate();
        wss.close();
        http.close(() => r());
      }),
  };
}

function settingFile(content: unknown, mode = 0o600): string {
  const dir = mkdtempSync(join(tmpdir(), "cnh-devtools-"));
  const file = join(dir, "devtools.json");
  if (content !== undefined) {
    writeFileSync(file, JSON.stringify(content));
    chmodSync(file, mode);
  }
  cleanups.push(() => rmSync(dir, { recursive: true, force: true }));
  return file;
}

describe("Mac browser setting file", () => {
  it("reports unsupported, off, unavailable and on", async () => {
    const cef = await fakeCef();
    cleanups.push(() => cef.close());
    const status = async (file: string, pidOk = true) => {
      const m = new MacBrowser({ file, hostName: "cmux15", pidCheck: async () => pidOk, pollMs: 60_000 });
      await m.start();
      m.stop();
      return { ...m.current, endpoint: m.endpoint };
    };
    expect(await status(settingFile(undefined))).toMatchObject({ state: "unsupported", hostName: "cmux15", endpoint: null });
    expect(await status(settingFile({ enabled: false }))).toMatchObject({ state: "off", endpoint: null });
    expect(await status(settingFile({ enabled: false, restartRequired: true }))).toMatchObject({ state: "off", restartRequired: true });
    expect(await status(settingFile({ port: cef.port, pid: 123 }, 0o644))).toMatchObject({ state: "unavailable", reason: expect.stringMatching(/readable by other users/) });
    expect(await status(settingFile({ port: cef.port, pid: 123 }), false)).toMatchObject({ state: "unavailable", reason: expect.stringMatching(/not running/) });
    expect(await status(settingFile({ port: 1, pid: 123 }))).toMatchObject({ state: "unavailable", reason: expect.stringMatching(/not answering/) });
    expect(await status(settingFile("nonsense"))).toMatchObject({ state: "unavailable" });
    expect(await status(settingFile({ port: cef.port, pid: 123 }))).toMatchObject({ state: "on", endpoint: `http://127.0.0.1:${cef.port}` });
  });

  it("matches daemon browser tabs to CEF targets by URL, title, then order", () => {
    const m = matchTargets(
      [
        { key: 1, url: "https://example.com/", title: "Example" },
        { key: 2, url: "https://dup.example/", title: "A" },
        { key: 3, url: "https://dup.example/", title: "B" },
        { key: 4, url: null, title: "Only title" },
        { key: 5, url: "https://gone.example/", title: "Gone" },
      ],
      [
        { id: "T-dupB", url: "https://dup.example", title: "B" },
        { id: "T-ex", url: "https://example.com/#top", title: "Example" },
        { id: "T-dupA", url: "https://dup.example/", title: "A" },
        { id: "T-title", url: "about:blank", title: "Only title" },
      ],
    );
    expect(Object.fromEntries(m)).toEqual({ 1: "T-ex", 2: "T-dupA", 3: "T-dupB", 4: "T-title" });
  });

  it("marks matched Mac browser panes streamable with the browser tab id", () => {
    const tree = { workspaces: [{ id: 1, active: true, screens: [{ id: 2, active: true, active_pane: 3, layout: { type: "leaf", pane: 3 }, panes: [{ id: 3, active_tab: 0, tabs: [{ surface: 5, kind: "browser", title: "Example", url: "https://example.com/" }, { surface: 6, kind: "browser", title: "Other", url: "https://other/" }] }] }] }] };
    const panes = mapDaemonLayout(tree as any, new Map([[5, "CEF1"]])).workspaces[0]!.panes;
    expect(panes[0]!.tabs).toEqual([
      { id: "t5", focused: true, kind: "browser", title: "Example", refId: "CEF1", streamable: true, url: "https://example.com/" },
      { id: "t6", focused: false, kind: "browser", title: "Other", streamable: false, url: "https://other/" },
    ]);
  });
});

describe("browser.* mirroring the Mac's tabs", () => {
  it("streams Mac tabs without changing what the Mac shows, and follows the setting", async () => {
    const cef = await fakeCef();
    cleanups.push(() => cef.close());
    const file = settingFile({ port: cef.port, pid: 42 });
    const mac = new MacBrowser({ file, hostName: "cmux15", pidCheck: async () => true, pollMs: 60_000 });
    await mac.start();
    cleanups.push(() => mac.stop());
    const { core, client } = await connectedCore({
      bridge: { mac },
      browser: { launch: false, resolveEndpoint: async () => null, preferEndpoint: () => mac.endpoint, mirror: (e) => e === mac.endpoint },
    });
    cleanups.push(() => core.shutdown());
    const hello = await client.hello();
    expect(hello.capabilities).toEqual(expect.arrayContaining(["browser.v1", "browser.mac.v1"]));
    expect(await client.request("browser.macStatus")).toMatchObject({ state: "on", hostName: "cmux15" });

    const { tabs } = await client.request("browser.list");
    expect(tabs.map((t: any) => t.id).sort()).toEqual(["CEF1", "CEF2"]);
    const { streamId } = await client.request("browser.attach", { tabId: "CEF1", width: 390, height: 844, scale: 3, mobile: true });
    expect(streamId).toBeGreaterThan(0);
    const methods = cef.calls.map((c) => c.method);
    for (const forbidden of ["Target.activateTarget", "Page.bringToFront", "Emulation.setDeviceMetricsOverride", "Emulation.setUserAgentOverride", "Page.reload"]) {
      expect(methods, forbidden).not.toContain(forbidden);
    }
    expect(methods).toContain("Page.startScreencast");
    await expect(client.request("browser.create", { url: "https://x.example" })).rejects.toMatchObject({ code: "unsupported" });
    await expect(client.request("browser.activate", { tabId: "CEF2" })).rejects.toMatchObject({ code: "unsupported" });
    await expect(client.request("browser.close", { tabId: "CEF2" })).rejects.toMatchObject({ code: "unsupported" });
    await client.request("browser.detach", { streamId });
    expect(cef.calls.map((c) => c.method)).not.toContain("Emulation.clearDeviceMetricsOverride");

    // The user turns the setting off: the phone hears it and the Mac tabs go away.
    const events: [string, any][] = [];
    client.peer.on("event", (t, p) => events.push([t, p]));
    writeFileSync(file, JSON.stringify({ enabled: false }));
    chmodSync(file, 0o600);
    await mac.check();
    await waitFor(() => events.some(([t, p]) => t === "browser.macStatus" && p.state === "off"));
    await waitFor(() => events.some(([t, p]) => t === "browser.closed" && p.tabId === "CEF1"));
  });
});
