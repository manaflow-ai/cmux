// l10n-allow-file: benchmark output, not shipped UI.
// The load modes every under-load harness shares (load-modes.json; cmuxterm-hq
// docs/design/chat-instant-under-load.md, "The bench"), and the knobs a page harness needs to put a page under one:
// the focused chat's stream, other chats open and streaming, the god transcript, and every core saturated by other
// processes. Leo, 2026-11-16: "but typing under load is not good enough".
//
// A harness takes `--modes L0,L2,L5` (or `all`), applies `mode.web` with `applyWebLoad`, and reports the mode's id
// beside every row, so a typing number and a tab-switch number were taken under the same load. `mode.webMissing`
// names what a page harness cannot express (terminals, workspaces); a harness prints it, so a row is never read as
// the full mode.
/// <reference types="bun" />
import os from "node:os";
import type { Browser, Page } from "playwright";
import registry from "./load-modes.json";
import { contentionFactor, probe } from "./hostLoad";

export type FocusedStream = { chunksPerSecond: number; toolLinesPerSecond: number };
export type WebLoad = {
  /// Transcript rows of the focused chat, or null for the harness's own length axis.
  rows: number | null;
  focusedStream: FocusedStream | null;
  otherChats: number;
  otherChatChunksPerSecond: number;
  cpuSaturation: boolean;
};
export type NativeLoad = {
  chats: number;
  busyTerminals: number;
  cpuSaturation: boolean;
  session: "light" | "stress";
};
export type LoadMode = {
  id: string;
  label: string;
  what: string;
  web: WebLoad;
  native: NativeLoad;
  webMissing?: string[];
  nativeMissing?: string[];
};

export const MODES: readonly LoadMode[] = registry.modes as unknown as readonly LoadMode[];
export const GATE_P95_MS: number = registry.gate_p95_ms;
/// What the pre-mode spellings meant: the composer bench's `--modes idle,stream` before the load modes landed.
const ALIASES: Record<string, string> = { idle: "L0", stream: "L1", load: "L1" };

export function modeById(id: string): LoadMode {
  const wanted = ALIASES[id.toLowerCase()] ?? id.toUpperCase();
  const mode = MODES.find((entry) => entry.id === wanted);
  if (!mode) throw new Error(`unknown load mode ${id}; have ${MODES.map((entry) => entry.id).join(",")}`);
  return mode;
}

/// `--modes` as modes: `all` is every mode in order, `idle`/`stream` are L0/L1 as the bench spelled them before.
export function parseModes(value: string | undefined, fallback = "L0"): LoadMode[] {
  const text = (value ?? fallback).trim();
  if (text === "all") return [...MODES];
  return text
    .split(",")
    .map((part) => part.trim())
    .filter(Boolean)
    .map(modeById);
}

/// The mock's streamed tool call is one log of this many lines (loadFixture.ts `streamedTool`), which is how a
/// lines-a-second rate becomes `tool_every` deltas.
const TOOL_LOG_LINES = 300;

/// `loadRun` options for a mode's focused stream: 60 chunks/s is a delta every 16.7 ms, and 2,000 lines/s is a tool
/// call (TOOL_LOG_LINES lines) every `tool_every` deltas.
export function focusedStreamOptions(stream: FocusedStream, seconds: number) {
  const chunkMs = Math.max(1, Math.round(1000 / stream.chunksPerSecond));
  const toolsPerSecond = stream.toolLinesPerSecond / TOOL_LOG_LINES;
  return {
    seconds,
    chunk_ms: chunkMs,
    tool_every: toolsPerSecond > 0 ? Math.max(1, Math.round(stream.chunksPerSecond / toolsPerSecond)) : 0,
    scroll_speed: 0,
  };
}

/// Transcript rows into `loadSeed` turns: a light turn is about three rows (a question, a reply and its live line).
export const turnsForRows = (rows: number) => Math.max(1, Math.round(rows / 3));

export type Burners = { count: number; stop(): void };

/// Every core saturated by other processes (mode L4): one spinning child process per core, each its own process, so
/// the page's renderer waits its turn for a core as it does on a loaded Mac. Only the children started here are
/// ever signalled.
export function startCpuBurners(count = os.cpus().length): Burners {
  const children = Array.from({ length: Math.max(1, count) }, () =>
    Bun.spawn([process.execPath, "-e", "let n=0;for(;;){n=Math.sqrt(n+1)}"], {
      stdout: "ignore",
      stderr: "ignore",
    }),
  );
  return {
    count: children.length,
    stop() {
      for (const child of children) {
        try {
          child.kill();
        } catch {
          // already gone
        }
      }
    },
  };
}

/// How much longer any CPU-bound work takes on this host right now than it would on it idle (hostLoad.ts): 1 with a
/// free core, about the oversubscription with every core taken. Reported per mode, so a row says the load was really
/// on (L4 and L5 read far above 1; L0 reads 1).
export const loadFactor = () => contentionFactor(probe());

export type OtherChats = { pages: Page[]; streams: Promise<unknown>[]; close(): Promise<void> };

/// Mode L2's other chats: `count` more pages of the pane on the same origin (the app gives each pane its own page,
/// so these are what 10 other chats open really are), each seeded with a small chat and streaming reply text at
/// `chunksPerSecond` for `seconds`. They are not shown beside the measured page; they are the cost of being open.
export async function openOtherChats(
  browser: Browser,
  port: number,
  count: number,
  chunksPerSecond: number,
  seconds: number,
  turns = 20,
): Promise<OtherChats> {
  const pages: Page[] = [];
  const streams: Promise<unknown>[] = [];
  for (let index = 0; index < count; index += 1) {
    const page = await browser.newPage({ viewport: { width: 900, height: 700 } });
    pages.push(page);
    await page.goto(`http://127.0.0.1:${port}/?mock`);
    await page.waitForFunction(() => "cmuxAcpmuxDebug" in window, null, { timeout: 60_000 });
    const seeded = (await page.evaluate(
      (value) => (window as any).cmuxAcpmuxDebug.loadSeed(value, { light: true }),
      turns,
    )) as Record<string, unknown>;
    if (seeded.error) throw new Error(`other chat ${index}: loadSeed: ${String(seeded.error)}`);
  }
  for (const page of pages)
    streams.push(
      page
        .evaluate(
          ([seconds, chunkMs]) =>
            (window as any).cmuxAcpmuxDebug.loadRun({
              seconds,
              chunk_ms: chunkMs,
              tool_every: 0,
              scroll_speed: 0,
            }),
          [seconds, Math.max(1, Math.round(1000 / Math.max(1, chunksPerSecond)))] as const,
        )
        .catch(() => undefined),
    );
  return {
    pages,
    streams,
    async close() {
      for (const page of pages) await page.close().catch(() => undefined);
    },
  };
}

/// The page-side probe the harness installs before the page loads: the long tasks on the page's main thread, the
/// frame intervals, and which frame drew each key (two keys in one frame are a burst, which is what Leo's recording
/// shows). Only Chromium reports `longtask`; in WebKit the long-task rows come back null.
export const TYPING_PROBE_SCRIPT = `(() => {
  const state = { longTasks: [], frames: [], keys: [], recording: false, longTaskSupport: false };
  window.__benchTypingLoad = state;
  try {
    new PerformanceObserver((list) => {
      if (!state.recording) return;
      for (const entry of list.getEntries()) state.longTasks.push(Math.round(entry.duration * 100) / 100);
    }).observe({ entryTypes: ["longtask"] });
    state.longTaskSupport = true;
  } catch { state.longTaskSupport = false; }
  let previous;
  const tick = (now) => {
    if (!state.recording) { previous = undefined; return; }
    if (previous !== undefined) state.frames.push(Math.round((now - previous) * 100) / 100);
    previous = now;
    requestAnimationFrame(tick);
  };
  document.addEventListener("keydown", (event) => {
    if (!state.recording) return;
    const at = event.timeStamp;
    requestAnimationFrame((now) => state.keys.push([Math.round(at * 100) / 100, Math.round(now * 100) / 100]));
  }, true);
  state.start = () => {
    state.longTasks.length = 0;
    state.frames.length = 0;
    state.keys.length = 0;
    state.recording = true;
    requestAnimationFrame(tick);
  };
  state.stop = () => { state.recording = false; };
})()`;

export type TypingProbe = {
  /// The longest task on the page's main thread over the run, and how many ran past a 60 Hz frame; null in WebKit.
  longest_task_ms: number | null;
  long_tasks: number | null;
  /// Frames whose interval missed a 60 Hz frame, and how many frames the run drew.
  frames_over_16ms: number;
  frames: number;
  /// Keys that shared their frame with another key: a burst, which is what typing in bursts looks like.
  keys_sharing_a_frame: number;
};

/// `__benchTypingLoad`'s raw arrays as rows (pure, so it is testable without a page).
export function summarizeTypingProbe(raw: {
  longTasks: number[];
  frames: number[];
  keys: [number, number][];
  longTaskSupport: boolean;
}): TypingProbe {
  const byFrame = new Map<number, number>();
  for (const [, frame] of raw.keys) byFrame.set(frame, (byFrame.get(frame) ?? 0) + 1);
  let shared = 0;
  for (const count of byFrame.values()) if (count > 1) shared += count;
  const sorted = [...raw.longTasks].sort((a, b) => a - b);
  return {
    longest_task_ms: raw.longTaskSupport ? (sorted.at(-1) ?? 0) : null,
    long_tasks: raw.longTaskSupport ? sorted.length : null,
    frames_over_16ms: raw.frames.filter((ms) => ms > 1000 / 60).length,
    frames: raw.frames.length,
    keys_sharing_a_frame: shared,
  };
}
