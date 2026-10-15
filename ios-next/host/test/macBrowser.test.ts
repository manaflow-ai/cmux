// The Mac's browser tabs over CEF DevTools (opt-in setting file), against a
// fake devtools.json and a fake CDP endpoint.
import { chmodSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { createServer, type Server } from "node:http";
import type { AddressInfo } from "node:net";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, describe, expect, it } from "vitest";
import { WebSocketServer } from "ws";
import { MacBrowser, macBrowserResolver } from "../src/bridge/macBrowser.ts";
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
          return reply({ currentIndex: 1, entries: [{ id: 1, url: "https://a.example/", title: "A" }, { id: 2, url: "https://example.com/", title: "Example" }] });
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
  it("reads the app's devtools.json states", async () => {
    const cef = await fakeCef();
    cleanups.push(() => cef.close());
    const status = async (file: string, pidOk = true) => {
      const m = new MacBrowser({ file, hostName: "cmux15", pidCheck: async () => pidOk, pollMs: 60_000 });
      await m.start();
      m.stop();
      return { ...m.current, endpoint: m.endpoint };
    };
    const ready = { version: 1, enabled: true, state: "ready", pid: 123, port: cef.port, startedAt: "2026-10-10T20:00:00Z" };
    expect(await status(settingFile(undefined))).toMatchObject({ state: "unsupported", hostName: "cmux15", endpoint: null });
    expect(await status(settingFile({ version: 1, enabled: false, state: "off", pid: 123 }))).toMatchObject({ state: "off", endpoint: null });
    expect(await status(settingFile({ version: 1, enabled: true, state: "waitingForBrowser", pid: 123 }))).toMatchObject({ state: "unavailable", reason: expect.stringMatching(/open a browser tab/) });
    expect(await status(settingFile({ version: 1, enabled: true, state: "restartRequired", pid: 123 }))).toMatchObject({ state: "unavailable", restartRequired: true });
    // Turned off while Chromium still has the endpoint: never use it.
    expect(await status(settingFile({ version: 1, enabled: false, state: "restartRequired", pid: 123, port: cef.port }))).toMatchObject({ state: "off", restartRequired: true, endpoint: null });
    expect(await status(settingFile(ready, 0o644))).toMatchObject({ state: "unavailable", reason: expect.stringMatching(/readable by other users/) });
    expect(await status(settingFile(ready), false)).toMatchObject({ state: "unavailable", reason: expect.stringMatching(/not running/) });
    expect(await status(settingFile({ ...ready, port: 1 }))).toMatchObject({ state: "unavailable", reason: expect.stringMatching(/not answering/) });
    expect(await status(settingFile("nonsense"))).toMatchObject({ state: "unavailable" });
    expect(await status(settingFile(ready))).toMatchObject({ state: "on", endpoint: `http://127.0.0.1:${cef.port}` });
  });

  it("pairs Mac browser tabs with targets only through the app's mapping", async () => {
    const cef = await fakeCef();
    cleanups.push(() => cef.close());
    const base = { version: 1, enabled: true, state: "ready", pid: 1, port: cef.port };
    const resolverFor = async (content: unknown, open: string[] | null = null) => {
      const m = new MacBrowser({ file: settingFile(content), hostName: "cmux15", pidCheck: async () => true, pollMs: 60_000 });
      await m.start();
      m.stop();
      return macBrowserResolver(m, () => open);
    };
    // No mapping published: never guess from URL or title.
    const noMap = await resolverFor(base);
    expect(noMap({ surface: 5 })).toEqual({ reason: expect.stringMatching(/does not say which browser target/) });
    const mapped = await resolverFor({ ...base, targets: [{ tabId: 5, targetId: "CEF1" }, { tabId: "tab_abc", targetId: "CEF2" }, { tabId: "t9", targetId: "CEF9" }] }, ["CEF1", "CEF2"]);
    expect(mapped({ surface: 5 })).toEqual({ refId: "CEF1" });
    expect(mapped({ surface: 6, tab_resource_id: "tab_abc" })).toEqual({ refId: "CEF2" });
    expect(mapped({ surface: 9 })).toEqual({ reason: expect.stringMatching(/not open/) });
    expect(mapped({ surface: 7 })).toEqual({ reason: expect.stringMatching(/not linked/) });
    // A target id in the daemon's tab state also counts.
    expect(mapped({ surface: 8, cdp_target_id: "CEF2" })).toEqual({ refId: "CEF2" });
    const off = await resolverFor({ version: 1, enabled: false, state: "off", pid: 1 });
    expect(off({ surface: 5 })).toEqual({ reason: "Turn on 'Allow cmux on iPhone to view browser tabs' in cmux Settings on cmux15" });
  });

  it("marks mapped Mac browser panes streamable and says which are shown on the Mac", () => {
    const tree = {
      workspaces: [
        { id: 1, active: true, screens: [{ id: 2, active: true, active_pane: 3, layout: { type: "leaf", pane: 3 }, panes: [{ id: 3, active_tab: 0, tabs: [{ surface: 5, kind: "browser", title: "Example", url: "https://example.com/" }, { surface: 6, kind: "browser", title: "Other", url: "https://other/" }] }] }] },
        { id: 7, active: false, screens: [{ id: 8, active: true, active_pane: 9, layout: { type: "leaf", pane: 9 }, panes: [{ id: 9, active_tab: 0, tabs: [{ surface: 10, kind: "browser", title: "Bg", url: "https://bg/" }] }] }] },
      ],
    };
    const map: Record<number, string> = { 5: "CEF1", 6: "CEF2", 10: "CEF10" };
    const layout = mapDaemonLayout(tree as any, (t) => (map[t.surface] ? { refId: map[t.surface]! } : { reason: "unmapped" }));
    expect(layout.workspaces[0]!.panes[0]!.tabs).toEqual([
      { id: "t5", focused: true, kind: "browser", title: "Example", visibleOnMac: true, url: "https://example.com/", refId: "CEF1", streamable: true },
      { id: "t6", focused: false, kind: "browser", title: "Other", visibleOnMac: false, url: "https://other/", refId: "CEF2", streamable: true },
    ]);
    // A mapped tab's page visibility wins over the daemon's selected tab
    // (the app's window can show another tab than the daemon reports).
    const byPage = mapDaemonLayout(tree as any, (t) => (map[t.surface] ? { refId: map[t.surface]!, visible: t.surface === 6 } : { reason: "unmapped" }));
    expect(byPage.workspaces[0]!.panes[0]!.tabs.map((t) => [t.id, t.focused, t.visibleOnMac])).toEqual([
      ["t5", true, false],
      ["t6", false, true],
    ]);
    // Selected in its pane but its workspace is not the one shown on the Mac.
    expect(layout.workspaces[1]!.panes[0]!.tabs[0]).toMatchObject({ focused: true, visibleOnMac: false });
    expect(mapDaemonLayout(tree as any).workspaces[0]!.panes[0]!.tabs[0]).toMatchObject({ streamable: false, reason: expect.any(String) });
  });
});

describe("browser.* mirroring the Mac's tabs", () => {
  it("streams Mac tabs without changing what the Mac shows, and follows the setting", async () => {
    const cef = await fakeCef();
    cleanups.push(() => cef.close());
    const file = settingFile({ version: 1, enabled: true, state: "ready", port: cef.port, pid: 42 });
    const mac = new MacBrowser({ file, hostName: "cmux15", pidCheck: async () => true, pollMs: 60_000 });
    await mac.start();
    cleanups.push(() => mac.stop());
    const broughtForward: string[] = [];
    const { core, client } = await connectedCore({
      bridge: { mac },
      browser: {
        launch: false,
        resolveEndpoint: async () => null,
        preferEndpoint: () => mac.endpoint,
        mirror: (e) => e === mac.endpoint,
        bringForward: async (tabId) => void broughtForward.push(tabId),
        createInMirror: async (url) => ({ id: "CEF-NEW", url, title: url, loading: true, progress: 0, canGoBack: false, canGoForward: false, active: true, streamable: true, paneId: "p3", layoutTabId: "t12" }),
      },
    });
    cleanups.push(() => core.shutdown());
    const hello = await client.hello();
    expect(hello.capabilities).toEqual(expect.arrayContaining(["browser.v1", "browser.mac.v1"]));
    expect(await client.request("browser.macStatus")).toMatchObject({ state: "on", hostName: "cmux15" });

    const { tabs } = await client.request("browser.list");
    expect(tabs.map((t: any) => t.id).sort()).toEqual(["CEF1", "CEF2"]);
    const { streamId } = await client.request("browser.attach", { tabId: "CEF1", width: 390, height: 844, scale: 3, mobile: true });
    expect(streamId).toBeGreaterThan(0);
    expect(broughtForward).toEqual([]); // never without the phone's opt-in
    const second = await client.request("browser.attach", { tabId: "CEF2", width: 390, height: 844, scale: 3, mobile: true, bringForward: true });
    expect(broughtForward).toEqual(["CEF2"]);
    await client.request("browser.detach", { streamId: second.streamId });
    const methods = cef.calls.map((c) => c.method);
    for (const forbidden of ["Target.activateTarget", "Page.bringToFront", "Emulation.setDeviceMetricsOverride", "Emulation.setUserAgentOverride", "Page.reload"]) {
      expect(methods, forbidden).not.toContain(forbidden);
    }
    expect(methods).toContain("Page.startScreencast");
    // New Tab while mirroring opens a tab in the Mac app (not the host's Chrome).
    const { tab: newTab } = await client.request("browser.create", { url: "x.example" });
    expect(newTab).toMatchObject({ id: "CEF-NEW", url: "https://x.example", streamable: true, paneId: "p3", layoutTabId: "t12" });
    expect(cef.calls.map((c) => c.method)).not.toContain("Target.createTarget");
    // History (back/forward long-press menus) on a Mac tab: the same CDP path.
    expect(await client.request("browser.history", { tabId: "CEF1" })).toEqual({
      currentIndex: 1,
      entries: [{ id: 1, url: "https://a.example/", title: "A" }, { id: 2, url: "https://example.com/", title: "Example" }],
    });
    await client.request("browser.goToHistory", { tabId: "CEF1", entryId: 1 });
    expect(cef.calls.filter((c) => c.method === "Page.navigateToHistoryEntry").map((c) => c.params)).toEqual([{ entryId: 1 }]);
    await expect(client.request("browser.activate", { tabId: "CEF2" })).rejects.toMatchObject({ code: "unsupported" });
    await expect(client.request("browser.close", { tabId: "CEF2" })).rejects.toMatchObject({ code: "unsupported" });
    await client.request("browser.detach", { streamId });
    expect(cef.calls.map((c) => c.method)).not.toContain("Emulation.clearDeviceMetricsOverride");

    // The user turns the setting off: the phone hears it and the Mac tabs go away.
    const events: [string, any][] = [];
    client.peer.on("event", (t, p) => events.push([t, p]));
    writeFileSync(file, JSON.stringify({ version: 1, enabled: false, state: "off", pid: 42 }));
    chmodSync(file, 0o600);
    await mac.check();
    await waitFor(() => events.some(([t, p]) => t === "browser.macStatus" && p.state === "off"));
    await waitFor(() => events.some(([t, p]) => t === "browser.closed" && p.tabId === "CEF1"));
  });
});

describe("devtools.json discovery", () => {
  it("finds the bridged tagged build's file by its bundle id", async () => {
    const { findDevtoolsFile } = await import("../src/bridge/macBrowser.ts");
    const { mkdirSync } = await import("node:fs");
    const home = mkdtempSync(join(tmpdir(), "cnh-home-"));
    cleanups.push(() => rmSync(home, { recursive: true, force: true }));
    const support = join(home, "Library", "Application Support");
    for (const b of ["com.cmuxterm.app", "com.cmuxterm.app.debug.nx.cefdt.v2", "com.cmuxterm.app.debug.other"]) {
      mkdirSync(join(support, b), { recursive: true });
      writeFileSync(join(support, b, "devtools.json"), "{}");
    }
    const prevHome = process.env.HOME;
    process.env.HOME = home;
    try {
      expect(findDevtoolsFile("nx-cefdt-v2")).toBe(join(support, "com.cmuxterm.app.debug.nx.cefdt.v2", "devtools.json"));
      expect(findDevtoolsFile(null)).toBe(join(support, "com.cmuxterm.app", "devtools.json"));
      expect(findDevtoolsFile("missing-tag")).toBe(join(support, "com.cmuxterm.app.debug.missing.tag", "devtools.json"));
    } finally {
      process.env.HOME = prevHome;
    }
  });
});

describe("show a Mac tab in the app", () => {
  it("refuses malformed tab ids and dead pids", async () => {
    const { selectTabInApp } = await import("../src/bridge/macBrowser.ts");
    await expect(selectTabInApp(process.pid, "tab_; rm -rf ~")).rejects.toThrow(/bad tab id/);
    await expect(selectTabInApp(999_999, "tab_0123456789abcdef0123456789abcdef")).rejects.toThrow(/not running/);
  });
});
