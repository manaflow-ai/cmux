// What a source save costs until it is on screen, per stage, on every page this dev server serves:
// in the Mac app (WebKit or Chromium pages, the agent pane, Settings) as in a browser. The page
// reports back over the HMR socket and the server logs one line per hot update and appends it to
// hot-swap-timing.ndjson in its state folder (CMUX_WEBVIEWS_DEV_STATE_DIR), so the in-app numbers
// need no film:
//
//   [cmux hot swap] ComposerFoot.tsx 38 ms: watch 9, server 1, socket 0, module 10, refresh 1, frame 17
//
//   watch    the file's mtime to Vite's watcher event (FSEvents on macOS)
//   server   the watcher event to the update message sent (hot update hooks, invalidation)
//   socket   sent to the page's `vite:beforeUpdate` (same machine: one wall clock)
//   module   the changed modules fetched and evaluated (`vite:afterUpdate`; in the app, its scheme handler)
//   refresh  React Fast Refresh after that (its re-render and commit)
//   frame    the commit to the end of the next drawn frame (requestAnimationFrame, then a message task)
//
// It also takes the timer out of React Fast Refresh: @vitejs/plugin-react's runtime coalesced an
// update's modules behind setTimeout(16), 16 ms on every save, and WebKit aligns a page's timers to
// 1 s (DOMTimer::hiddenPageAlignmentInterval) while it is visually idle (PageClientImplMac
// isVisuallyIdle: the app's windows stopped changing, as when another app is in front), where that
// one timer can hold a save back up to a second. The refresh now runs in the task after the update's callbacks, which
// coalesces them the same way.
//
// Serve only. CMUX_HOT_SWAP_FAST=off keeps the timer (the timing stays, so a before and an after read
// the same stages); CMUX_HOT_SWAP_TIMING=off leaves the timing out.
import fs from "node:fs";
import path from "node:path";
import type { Plugin, ViteDevServer } from "vite-plus";

import { devBase } from "./devEntrySrc";
import { devStateDirectory } from "./viewerEmptyHost";

const CLIENT_ID = "virtual:cmux-hot-swap-timing-client";
const RESOLVED_CLIENT_ID = `\0${CLIENT_ID}`;
export const HOT_SWAP_TIMING_EVENT = "cmux:hot-swap-timing";
export const REFRESHED_EVENT = "cmux:react-refreshed";
const REFRESH_RUNTIME = "/@react-refresh";
/// How long after its commit an update may still report its frame (a hidden page draws none).
const NO_FRAME_MS = 2000;

/// The runtime's debounce, as @vitejs/plugin-react 6 writes it.
const DEBOUNCE =
  /function debounce\(fn, delay\) \{\n {2}let handle\n {2}return \(\) => \{\n {4}clearTimeout\(handle\)\n {4}handle = setTimeout\(fn, delay\)\n {2}\}\n\}/;
const REFRESH_CALL = /\n {2}performReactRefresh\(\)\n\}, 16\)/;

/// @vitejs/plugin-react's refresh runtime with its timer replaced: one refresh per task, run by a
/// message task (never throttled as a DOM timer is), after which REFRESHED_EVENT fires. Undefined
/// when the runtime no longer reads as expected (then it is served as it is).
export function refreshRuntimeWithoutTimer(code: string): string | undefined {
  if (!DEBOUNCE.test(code) || !REFRESH_CALL.test(code)) return undefined;
  return code
    .replace(
      DEBOUNCE,
      `function debounce(fn) {
  // cmux (dev-server/hotSwapTiming.ts): a message task, not setTimeout(fn, 16). The callbacks of one
  // update run in one task, so this still coalesces them; a timer cost 16 ms, or up to 1 s in a
  // WebKit page that is visually idle.
  const channel = new MessageChannel()
  let queued = false
  channel.port1.onmessage = () => {
    queued = false
    fn()
  }
  return () => {
    if (queued) return
    queued = true
    channel.port2.postMessage(null)
  }
}`,
    )
    .replace(
      REFRESH_CALL,
      `\n  performReactRefresh()\n  window.dispatchEvent(new Event(${JSON.stringify(REFRESHED_EVENT)}))\n})`,
    );
}

/// The page's half: times each update from its message to its next drawn frame and sends it back.
export const CLIENT_SOURCE = `if (import.meta.hot) {
  const at = () => performance.timeOrigin + performance.now();
  const pending = new Map();
  let refreshed = 0;
  window.addEventListener(${JSON.stringify(REFRESHED_EVENT)}, () => (refreshed = at()));
  const frame = () => new Promise((resolve) => requestAnimationFrame(() => {
    const channel = new MessageChannel();
    channel.port1.onmessage = () => resolve(at());
    channel.port2.postMessage(null);
  }));
  import.meta.hot.on("vite:beforeUpdate", (payload) => {
    const stamp = payload.updates?.[0]?.timestamp;
    if (stamp !== undefined) pending.set(stamp, { received: at(), refreshedBefore: refreshed });
  });
  import.meta.hot.on("vite:afterUpdate", (payload) => {
    const stamp = payload.updates?.[0]?.timestamp;
    const mark = pending.get(stamp);
    if (!mark) return;
    pending.delete(stamp);
    mark.applied = at();
    const js = payload.updates.some((u) => u.type === "js-update");
    // A JS update's React refresh runs in a task after this one; a stylesheet has none. No timer
    // waits for it (a throttled page would delay the report): the refresh's own event does, and a
    // module that is no refresh boundary is reported without one.
    const settle = !js || refreshed > mark.refreshedBefore
      ? Promise.resolve()
      : new Promise((resolve) => {
          const done = () => { window.removeEventListener(${JSON.stringify(REFRESHED_EVENT)}, done); resolve(); };
          window.addEventListener(${JSON.stringify(REFRESHED_EVENT)}, done);
          const channel = new MessageChannel();
          channel.port1.onmessage = () => { const again = new MessageChannel(); again.port1.onmessage = done; again.port2.postMessage(null); };
          channel.port2.postMessage(null);
        });
    // Sent at the commit, then again once a frame is drawn: a page that draws none (hidden, or
    // throttled) still reports its stages up to the commit.
    const report = (painted) =>
      import.meta.hot.send(${JSON.stringify(HOT_SWAP_TIMING_EVENT)}, {
        timestamp: stamp, page: location.href, received: mark.received, applied: mark.applied,
        refreshed: refreshed > mark.refreshedBefore ? refreshed : undefined, painted,
      });
    settle.then(() => {
      report(undefined);
      return frame();
    }).then(report);
  });
}
`;

export type HotSwapServerMarks = { file: string; mtime: number; watch: number; sent?: number };
export type HotSwapPageMarks = { received: number; applied: number; refreshed?: number; painted?: number };

/// The stages of one update, in whole ms (see the top of this file).
export function hotSwapStages(server: HotSwapServerMarks, page: HotSwapPageMarks) {
  const ms = (a: number | undefined, b: number | undefined) =>
    a === undefined || b === undefined ? undefined : Math.round(b - a);
  const committed = page.refreshed ?? page.applied;
  return {
    total: ms(server.mtime, page.painted),
    committed: ms(server.mtime, committed),
    watch: ms(server.mtime, server.watch),
    server: ms(server.watch, server.sent),
    socket: ms(server.sent, page.received),
    module: ms(page.received, page.applied),
    refresh: page.refreshed === undefined ? undefined : ms(page.applied, page.refreshed),
    frame: ms(committed, page.painted),
  };
}

export function formatHotSwap(file: string, stages: ReturnType<typeof hotSwapStages>): string {
  const parts = (["watch", "server", "socket", "module", "refresh", "frame"] as const)
    .filter((key) => stages[key] !== undefined)
    .map((key) => `${key} ${stages[key]}`);
  const total =
    stages.total === undefined
      ? `committed in ${stages.committed} ms, no frame drawn in ${NO_FRAME_MS} ms`
      : `${stages.total} ms`;
  return `[cmux hot swap] ${path.basename(file)} ${total}: ${parts.join(", ")}`;
}

export function hotSwapTiming(): Plugin {
  const off = process.env.CMUX_HOT_SWAP_TIMING === "off";
  const slow = process.env.CMUX_HOT_SWAP_FAST === "off";
  let base = "/";
  // The newest saves by file, then each sent update by its timestamp.
  const saves = new Map<string, HotSwapServerMarks>();
  const sent = new Map<number, HotSwapServerMarks>();
  return {
    name: "cmux-hot-swap-timing",
    apply: "serve",
    enforce: "post",
    configResolved(config) {
      base = devBase(config.base);
    },
    configureServer(server: ViteDevServer) {
      if (off) return;
      const port = server.config.server.port ?? 0;
      const log = path.join(devStateDirectory(port), "hot-swap-timing.ndjson");
      server.watcher.on("change", (file) => {
        const watch = Date.now();
        let mtime = watch;
        try {
          mtime = fs.statSync(file).mtimeMs;
        } catch {}
        saves.set(file, { file, mtime: Math.min(mtime, watch), watch });
      });
      const send = server.ws.send.bind(server.ws) as (...args: unknown[]) => void;
      server.ws.send = ((...args: unknown[]) => {
        const payload = args[0] as { type?: string; updates?: { path: string; timestamp: number }[] } | undefined;
        if (payload?.type === "update" && payload.updates?.length) {
          const stamp = payload.updates[0].timestamp;
          // The save this update answers: the newest one whose module it carries, else the newest.
          const newest = [...saves.values()].sort((a, b) => b.watch - a.watch);
          const match =
            newest.find((save) => payload.updates!.some((u) => save.file.endsWith(u.path.split("?")[0]))) ?? newest[0];
          if (match) {
            sent.set(stamp, { ...match, sent: Date.now() });
            saves.delete(match.file);
          }
          for (const key of [...sent.keys()].slice(0, -20)) sent.delete(key);
        }
        return send(...args);
      }) as typeof server.ws.send;
      // Per update and page: the commit report waits for its frame report, or NO_FRAME_MS.
      const waiting = new Map<string, ReturnType<typeof setTimeout>>();
      const record = (marks: HotSwapServerMarks, data: HotSwapPageMarks & { page: string }) => {
        const stages = hotSwapStages(marks, data);
        server.config.logger.info(formatHotSwap(marks.file, stages), { timestamp: true });
        try {
          fs.mkdirSync(path.dirname(log), { recursive: true });
          fs.appendFileSync(
            log,
            `${JSON.stringify({ at: new Date().toISOString(), file: marks.file, page: data.page, ...stages })}\n`,
          );
        } catch {}
      };
      server.ws.on(HOT_SWAP_TIMING_EVENT, (data: HotSwapPageMarks & { timestamp: number; page: string }) => {
        const marks = sent.get(data.timestamp);
        if (!marks) return;
        const key = `${data.timestamp} ${data.page}`;
        clearTimeout(waiting.get(key));
        waiting.delete(key);
        if (data.painted !== undefined) return record(marks, data);
        waiting.set(
          key,
          setTimeout(() => {
            waiting.delete(key);
            record(marks, data);
          }, NO_FRAME_MS),
        );
      });
    },
    resolveId(id) {
      return id === CLIENT_ID ? RESOLVED_CLIENT_ID : undefined;
    },
    load(id) {
      return id === RESOLVED_CLIENT_ID ? CLIENT_SOURCE : undefined;
    },
    transform(code, id) {
      if (slow || id !== REFRESH_RUNTIME) return undefined;
      const patched = refreshRuntimeWithoutTimer(code);
      if (!patched) {
        this.warn("React Fast Refresh's runtime changed; its 16 ms timer stays (dev-server/hotSwapTiming.ts)");
        return undefined;
      }
      return { code: patched, map: null };
    },
    transformIndexHtml: () =>
      off ? [] : [{ tag: "script", attrs: { type: "module", src: `${base}@id/${CLIENT_ID}` }, injectTo: "head" }],
  };
}
