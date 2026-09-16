import { describe, expect, test } from "bun:test";
import { readFile } from "node:fs/promises";
import { createRequire } from "node:module";
import vm from "node:vm";
import ts from "typescript";

const require = createRequire(import.meta.url);

class Events {
  private listeners = new Map<string, Set<() => void>>();
  visibilityState = "visible";
  addEventListener(event: string, callback: () => void) {
    const callbacks = this.listeners.get(event) ?? new Set();
    callbacks.add(callback);
    this.listeners.set(event, callbacks);
  }
  emit(event: string) {
    for (const callback of this.listeners.get(event) ?? []) callback();
  }
}

async function harness(esm: boolean) {
  const instances: Socket[] = [];
  class Socket {
    static OPEN = 1;
    static CONNECTING = 0;
    OPEN = 1;
    readyState = 0;
    onopen: (() => void) | null = null;
    onerror: (() => void) | null = null;
    onclose: (() => void) | null = null;
    onmessage: ((event: { data: string }) => void) | null = null;
    sent: string[] = [];
    constructor(readonly url: string) { instances.push(this); }
    open() { this.readyState = 1; this.onopen?.(); }
    close() { this.readyState = 3; this.onclose?.(); }
    send(data: string) { this.sent.push(data); }
  }
  const page = new Events();
  const document = new Events();
  let reloads = 0;
  const timers = new Map<number, () => void>();
  let timerID = 0;
  const module = { exports: {} as { createWebSocket: (prefix: string, state: object) => Socket } };
  const dependencies = (id: string) => {
    if (id.endsWith("get-socket-url")) return { getSocketUrl: () => "wss://backend.test:4405" };
    if (id.endsWith("forward-logs")) return { logQueue: { onSocketReady() {} } };
    if (id.endsWith("constants")) return { WEB_SOCKET_MAX_RECONNECTIONS: 25 };
    if (id.endsWith("hot-reloader-types")) return { HMR_MESSAGE_SENT_TO_BROWSER: { TURBOPACK_CONNECTED: "connected", SYNC: "sync" } };
    if (id.endsWith("hot-reloader-app")) return { processMessage() {}, performFullReload() {} };
    if (id.endsWith("shared")) return { reportInvalidHmrMessage(_event: unknown, error: Error) { throw error; } };
    return {};
  };
  const entrypoint = require.resolve(`next/dist/${esm ? "esm/" : ""}client/dev/hot-reloader/app/web-socket.js`);
  // Execute the installed dependency, not a copy of its algorithm. The ESM
  // distribution is the browser's entrypoint; CJS is exercised as well.
  const installedSource = await readFile(entrypoint, "utf8");
  const source = esm ? ts.transpileModule(installedSource, {
    compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2022 },
  }).outputText : installedSource;
  vm.runInNewContext(source, {
    module, exports: module.exports, require: dependencies,
    window: Object.assign(page, { WebSocket: Socket, console: { log() {} }, location: { reload() { reloads++; } } }),
    document, WebSocket: Socket, self: { __next_r: "fixture" }, TextDecoder,
    process: { env: {} },
    setTimeout: (callback: () => void) => { timers.set(++timerID, callback); return timerID; },
    clearTimeout: (id: number) => timers.delete(id),
  });
  module.exports.createWebSocket("", {});
  return { instances, page, document, timers, reloads: () => reloads };
}

for (const esm of [false, true]) {
  describe(`Next HMR page lifecycle (${esm ? "ESM" : "CJS"})`, () => {
    test("closes before page caching and reconnects once on restoration", async () => {
      const h = await harness(esm);
      h.instances[0]!.open();
      h.page.emit("pagehide");
      expect(h.instances[0]!.readyState).toBe(3);
      expect(h.timers.size).toBe(0);
      h.document.emit("visibilitychange");
      h.page.emit("online");
      expect(h.instances).toHaveLength(1);
      h.page.emit("pageshow");
      h.document.emit("visibilitychange");
      h.page.emit("online");
      h.page.emit("pageshow");
      expect(h.instances).toHaveLength(2);
      expect(h.instances[1]!.url).toBe("wss://backend.test:4405/_next/hmr?id=fixture");
      expect(h.reloads()).toBe(0);
    });

    test("cancels queued retries and ignores events from the retired socket", async () => {
      const h = await harness(esm);
      const oldError = h.instances[0]!.onerror!;
      oldError();
      expect(h.timers.size).toBe(1);
      const staleRetry = [...h.timers.values()][0]!;
      h.page.emit("pagehide");
      expect(h.timers.size).toBe(0);
      staleRetry();
      expect(h.instances).toHaveLength(1);
      h.page.emit("pageshow");
      h.instances[1]!.open();
      oldError();
      expect(h.timers.size).toBe(0);
      expect(h.instances[1]!.readyState).toBe(1);
    });

    test("still retries genuine connection loss while the page is active", async () => {
      const h = await harness(esm);
      h.instances[0]!.open();
      h.instances[0]!.onerror!();
      expect(h.timers.size).toBe(1);
      [...h.timers.values()][0]!();
      expect(h.instances).toHaveLength(2);
      expect(h.reloads()).toBe(0);
    });
  });
}
