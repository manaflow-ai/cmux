// l10n-allow-file: bench fixture titles, not shipped UI.
// Idle work of an agent page on a busy Mac (cmuxterm-hq#4878 finding 1): 3,055 chats listed, the
// shown chat streaming. Measures, in-process under jsdom:
//   - the reload copy (`saveSnapshot`): bytes per write, ms per write, and whether it fits
//     sessionStorage's quota (5M UTF-16 characters, Chromium and WebKit);
//   - a hidden page's frame work (`nextFrame`): how often a stream draws in 10 s while hidden.
//
//   bun scripts/agent-pane/hidden-idle-bench.ts [--sessions 3055] [--rows 400] [--out FILE]
//
// Run it from webviews/ at two commits for a before/after on the same harness.
import { JSDOM, VirtualConsole } from "jsdom";
import { writeFileSync } from "node:fs";

const arg = (name: string, fallback: string) => {
  const index = process.argv.indexOf(`--${name}`);
  return index >= 0 ? process.argv[index + 1]! : fallback;
};
const SESSIONS = Number(arg("sessions", "3055"));
const ROWS = Number(arg("rows", "400"));
const QUOTA_CHARS = 5 * 1024 * 1024;

const dom = new JSDOM("<!doctype html><div id=root></div>", {
  url: "http://localhost/",
  pretendToBeVisual: true,
  virtualConsole: new VirtualConsole(),
});
let visibility: "visible" | "hidden" = "visible";
Object.defineProperty(dom.window.document, "visibilityState", { configurable: true, get: () => visibility });
const writes: { chars: number; stored: boolean }[] = [];
const scope = globalThis as Record<string, unknown>;
Object.assign(scope, {
  window: dom.window,
  document: dom.window.document,
  navigator: dom.window.navigator,
  HTMLElement: dom.window.HTMLElement,
  Element: dom.window.Element,
  customElements: dom.window.customElements,
  Node: dom.window.Node,
  MutationObserver: dom.window.MutationObserver,
  sessionStorage: {
    getItem: () => null,
    setItem: (_key: string, value: string) => {
      const stored = value.length <= QUOTA_CHARS;
      writes.push({ chars: value.length, stored });
      if (!stored) throw new dom.window.DOMException("quota", "QuotaExceededError");
    },
    removeItem: () => {},
  },
  requestAnimationFrame: dom.window.requestAnimationFrame.bind(dom.window),
  cancelAnimationFrame: dom.window.cancelAnimationFrame.bind(dom.window),
});
for (const key of Object.getOwnPropertyNames(dom.window))
  if (/^(HTML|SVG|CSS|Shadow|Document|Mutation)/.test(key) && !(key in scope))
    scope[key] = (dom.window as unknown as Record<string, unknown>)[key];

const { saveSnapshot } = await import("../../src/agent-session/acpmux/App");
const { nextFrame } = await import("../../src/agent-session/acpmux/direct");

const id = (n: number) => `0190a000-0000-7000-8000-${n.toString(16).padStart(12, "0")}`;
const sessions = Array.from({ length: SESSIONS }, (_, n) => ({
  sessionId: id(n),
  displayTitle: `Fix the flaky test in module ${n}`,
  title: `Fix the flaky test in module ${n} and check the nightly`,
  harness: n % 3 ? "claude" : "codex",
  status: n % 80 ? "idle" : "running",
  model: "opus",
  cwd: `/Users/someone/Projects/repo-${n % 40}`,
  updatedAt: 1_760_000_000_000 + n * 1000,
  activityAt: 1_760_000_000_000 + n * 1000,
  createdAt: 1_759_000_000_000 + n * 1000,
  host: "This Mac",
  hostKind: "local",
  branch: `lane/fix-${n}`,
  preview: "I ran the suite three times and the failure is in the setup of the fixture, not the code under test.",
  lastMessage: "Pushed the fix and opened the PR; CI is running.",
}));
const rows = Array.from({ length: ROWS }, (_, n) => ({
  id: `row-${n}`,
  kind: n % 2 ? "assistant" : "user",
  seq: n + 1,
  version: 1,
  text: "A paragraph of the reply that streams in while the chat runs. ".repeat(6),
}));
const snapshot = (n: number, list = sessions) => ({
  type: "snapshot",
  protocolVersion: 1,
  rows: [...rows.slice(0, -1), { ...rows.at(-1)!, text: `${rows.at(-1)!.text} ${n}` }],
  sessions: list,
  sessionId: id(SESSIONS - 1),
  connection: "connected",
  isWorking: true,
  queue: [],
  catalog: [],
  canLoadOlder: false,
});

const median = (values: number[]) => [...values].sort((a, b) => a - b)[Math.floor(values.length / 2)]!;
function writeCost(fresh: boolean) {
  writes.length = 0;
  const times: number[] = [];
  for (let n = 0; n < 30; n++) {
    // A streaming frame keeps the list; a session change makes a new one.
    saveSnapshot(snapshot(n, fresh ? [...sessions] : sessions) as never);
    const started = performance.now();
    dom.window.dispatchEvent(new dom.window.Event("pagehide"));
    times.push(performance.now() - started);
  }
  return { ms: median(times), chars: writes.at(-1)!.chars, fits: writes.every((write) => write.stored) };
}
const streaming = writeCost(false);
const listChanged = writeCost(true);

// A chat streaming into a hidden page: an event every 16 ms asks for a frame, one at a time as
// `emitInFrame` does, for 2 s; then the page shows.
const STREAM_MS = 2000;
let draws = 0;
let pending = false;
visibility = "hidden";
dom.window.document.dispatchEvent(new dom.window.Event("visibilitychange"));
const stream = setInterval(() => {
  if (pending) return;
  pending = true;
  nextFrame(() => {
    pending = false;
    draws += 1;
  });
}, 16);
await new Promise((done) => setTimeout(done, STREAM_MS));
clearInterval(stream);
const hiddenDraws = draws;
visibility = "visible";
dom.window.document.dispatchEvent(new dom.window.Event("visibilitychange"));
await new Promise((done) => setTimeout(done, 150));
const drewOnShow = draws - hiddenDraws;

const result = {
  sessions: SESSIONS,
  rows: ROWS,
  reloadCopy: {
    streamingFrame: { msPerWrite: +streaming.ms.toFixed(2), chars: streaming.chars, fitsQuota: streaming.fits },
    listChanged: { msPerWrite: +listChanged.ms.toFixed(2), chars: listChanged.chars, fitsQuota: listChanged.fits },
  },
  hiddenPage: { drawsPer10s: Math.round((hiddenDraws * 10_000) / STREAM_MS), drewOnShow },
};
console.log(JSON.stringify(result, null, 2));
const out = arg("out", "");
if (out) writeFileSync(out, JSON.stringify(result, null, 2));
dom.window.close();
process.exit(0);
