// l10n-allow-file: bench fixtures.
// Leo 2026-11-18: "The templates should be like the customixastikms api you can build them i don't
// think they should ship as is". Before/after numbers for removing the cards/default/threads/console
// New Tab templates: the per-snapshot chat model work and the page mount each saved template id costs
// at his scale (10,790 chats), resolved the way the host does (parseNewTabTemplate -> shownTemplate ->
// screenTemplate -> screenSections). Prints one JSON line per measure (BENCH {...}).
import { afterAll, beforeAll, expect, test } from "bun:test";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import { noChat } from "../src/gallery/fixtures/acpmux";
import * as screenModel from "../src/agent-session/acpmux/newtab/screenModel";
import * as templates from "../src/agent-session/acpmux/newtab/templates";
// The bench reads templates/screenModel by name so it runs unchanged before and after the removal.
import { NewTabScreen } from "../src/agent-session/acpmux/newtab/NewTabScreen";
import { proseMirrorGlobals } from "../src/agent-session/acpmux/promptFieldTesting";
import { translate } from "../src/agent-session/acpmux/i18n";
import type { AcpmuxSessionEntry } from "../src/agent-session/acpmux/sessionList";
import type { DeviceChat } from "../src/agent-session/acpmux/newtab/deviceChats";

const IDS = ["minimal", "cards", "default", "threads", "console"] as const;
const CHATS = Number(process.env.NT_BENCH_CHATS ?? 10_790);
const DEVICE = Number(process.env.NT_BENCH_DEVICE ?? 2_000);
const MODEL_ITERS = Number(process.env.NT_BENCH_MODEL_ITERS ?? 200);
const MOUNTS = Number(process.env.NT_BENCH_MOUNTS ?? 9);
const NOW = 1_800_000_000_000;
const T = translate as unknown as (key: string) => string;

// Deterministic list shaped like his: a quarter child chats, some archived, a few waiting on him.
function rng(seed: number) {
  return () => (seed = (seed * 1_103_515_245 + 12_345) % 2 ** 31) / 2 ** 31;
}
function fixture(): { sessions: AcpmuxSessionEntry[]; device: DeviceChat[] } {
  const r = rng(46_331);
  const sessions: AcpmuxSessionEntry[] = [];
  const parents: string[] = [];
  for (let index = 0; index < CHATS; index++) {
    const id = `s${index}`;
    const child = parents.length > 50 && r() < 0.25;
    const roll = r();
    const entry: AcpmuxSessionEntry = {
      sessionId: id,
      displayTitle: `Chat ${index} about the fetch helper`,
      harness: r() < 0.5 ? "claude" : "codex",
      status: "idle",
      cwd: `/Users/x/Projects/p${index % 400}`,
      host: index % 27 === 0 ? "This Mac" : `peer-${index % 27}`,
      hostKind: index % 27 === 0 ? "local" : "remote",
      pendingPermissions: roll < 0.01 ? 1 : 0,
      updatedAt: NOW - Math.floor(r() * 90 * 86_400_000),
      preview: `Last reply line ${index}`,
      agentSessionId: `a${index}`,
      ...(roll > 0.95 ? { archived: true } : {}),
      ...(roll > 0.93 && roll <= 0.95 ? { indicator: "failed" as never } : {}),
      ...(child ? { spawnedBy: parents[Math.floor(r() * parents.length)] } : {}),
    } as AcpmuxSessionEntry;
    if (!child) parents.push(id);
    sessions.push(entry);
  }
  const device: DeviceChat[] = Array.from({ length: DEVICE }, (_, index) => ({
    key: `claude:d${index}`,
    harness: "claude",
    title: `Device chat ${index}`,
    updatedAt: NOW - Math.floor(r() * 90 * 86_400_000),
    ...(r() < 0.1 ? { parent: `claude:d${Math.floor(r() * DEVICE)}` } : {}),
  }));
  return { sessions, device };
}

type Sections = { chats: "cards" | "list" | "none"; stage: boolean; recent: number };
const NO_SECTIONS: Sections = { chats: "none", stage: false, recent: 0 };
const model = screenModel as Record<string, unknown>;

// The host's path from a saved `tabs.newTabTemplate` value to the screen the page draws.
function resolve(id: string) {
  const t = templates as Record<string, unknown>;
  const parsed = (t.parseNewTabTemplate as (v: unknown) => string | undefined)(id);
  const shown = (t.shownTemplate as (h: { template?: string; layout: "a" | "b" }) => string)({
    ...(parsed ? { template: parsed } : {}),
    layout: "b",
  });
  // After the removal there are no screen templates: every page is Minimal and lists no chats.
  const screen =
    typeof t.screenTemplate === "function" ? (t.screenTemplate as (v: string) => string)(shown) : "minimal";
  const sections: Sections =
    typeof t.screenSections === "function" ? (t.screenSections as (v: string) => Sections)(screen) : NO_SECTIONS;
  return { parsed, shown, screen, sections };
}

function counted(sessions: AcpmuxSessionEntry[]) {
  let reads = 0;
  const wrapped = sessions.map(
    (s) =>
      new Proxy(s, {
        get(target, key, receiver) {
          reads += 1;
          return Reflect.get(target, key, receiver);
        },
      }),
  );
  return { wrapped, reads: () => reads };
}

const stats = (xs: number[]) => {
  const s = [...xs].sort((a, b) => a - b);
  const q = (p: number) => s[Math.min(s.length - 1, Math.floor(p * s.length))]!;
  return { median: +q(0.5).toFixed(4), p95: +q(0.95).toFixed(4), min: +s[0]!.toFixed(4), max: +s.at(-1)!.toFixed(4) };
};

const { sessions, device } = fixture();

// What NewTabScreen recomputes per snapshot from the chat list for a template (its useMemos at
// NewTabScreen.tsx pageChatCards / needsYouCards).
function snapshotWork(sections: Sections, list: AcpmuxSessionEntry[]) {
  // After the removal these functions are gone with the templates: no per-snapshot chat pass.
  type Fn = (...args: unknown[]) => unknown[];
  const cards =
    typeof model.pageChatCards === "function" ? (model.pageChatCards as Fn)(sections, list, NOW, T, device) : [];
  const needs =
    sections.stage && typeof model.needsYouCards === "function" ? (model.needsYouCards as Fn)(list, NOW, T) : [];
  return cards.length + needs.length;
}

test("model work per snapshot at 10K chats, per saved template id", () => {
  for (const id of IDS) {
    const r = resolve(id);
    const { wrapped, reads } = counted(sessions);
    const shown = snapshotWork(r.sections, wrapped);
    const fieldReads = reads();
    for (let i = 0; i < 20; i++) snapshotWork(r.sections, sessions);
    const times: number[] = [];
    for (let i = 0; i < MODEL_ITERS; i++) {
      const start = performance.now();
      snapshotWork(r.sections, sessions);
      times.push(performance.now() - start);
    }
    console.log(
      `BENCH ${JSON.stringify({ measure: "model", id, screen: r.screen, chats: r.sections.chats, stage: r.sections.stage, cards: shown, fieldReads, ms: stats(times), n: MODEL_ITERS, sessions: sessions.length, device: device.length })}`,
    );
  }
  expect(true).toBe(true);
});

let dom: JSDOM;
const scope = globalThis as Record<string, unknown>;
beforeAll(() => {
  dom = new JSDOM("<!doctype html><html><body><main id=root></main></body></html>", { url: "http://localhost/" });
  Object.assign(scope, {
    ...proseMirrorGlobals(dom.window as unknown as Window & typeof globalThis),
    window: dom.window,
    document: dom.window.document,
    navigator: dom.window.navigator,
    Node: dom.window.Node,
    HTMLElement: dom.window.HTMLElement,
    Element: dom.window.Element,
    getComputedStyle: dom.window.getComputedStyle.bind(dom.window),
    ResizeObserver: class {
      observe() {}
      unobserve() {}
      disconnect() {}
    },
    requestAnimationFrame: (cb: FrameRequestCallback) => setTimeout(() => cb(Date.now()), 0) as unknown as number,
    cancelAnimationFrame: (h: number) => clearTimeout(h),
    IS_REACT_ACT_ENVIRONMENT: true,
  });
  Object.assign(dom.window, { ResizeObserver: scope.ResizeObserver });
});
afterAll(() => dom.window.close());

const props = {
  onAsk: () => {},
  onOpen: (_url: string) => {},
  onSearch: (_text: string) => {},
  onShell: () => {},
  onJump: () => {},
  onOpenSession: () => {},
  onShowAll: () => {},
};

test("NewTabScreen mount and one-chat delta at 10K chats, per saved template id", async () => {
  let reads = 0;
  const watch = (list: AcpmuxSessionEntry[]) =>
    list.map(
      (s) =>
        new Proxy(s, {
          get(target, key, receiver) {
            reads += 1;
            return Reflect.get(target, key, receiver);
          },
        }),
    );
  const snapshot = noChat(sessions);
  const changedList = sessions.map((s, i) => (i === 7 ? { ...s, updatedAt: NOW, preview: "changed" } : s));
  const changed = noChat(changedList);
  // A first, unlogged pass warms the JIT, so the first id measured is not charged for it.
  for (const [pass, id] of (["minimal", ...IDS] as string[]).entries()) {
    const r = resolve(id);
    const mounts: number[] = [];
    const deltas: number[] = [];
    let drawn = 0;
    let mountReads = 0;
    let deltaReads = 0;
    // One counted mount + delta: chat field reads the page makes at 10K chats.
    {
      const container = dom.window.document.createElement("div");
      dom.window.document.body.appendChild(container);
      const root: Root = createRoot(container);
      reads = 0;
      await act(async () =>
        root.render(<NewTabScreen {...props} template={r.screen as never} snapshot={noChat(watch(sessions))} />),
      );
      mountReads = reads;
      reads = 0;
      await act(async () =>
        root.render(<NewTabScreen {...props} template={r.screen as never} snapshot={noChat(watch(changedList))} />),
      );
      deltaReads = reads;
      act(() => root.unmount());
      container.remove();
    }
    for (let run = 0; run < MOUNTS + 1; run++) {
      const container = dom.window.document.createElement("div");
      dom.window.document.body.appendChild(container);
      const root: Root = createRoot(container);
      const start = performance.now();
      await act(async () => root.render(<NewTabScreen {...props} template={r.screen as never} snapshot={snapshot} />));
      const mounted = performance.now() - start;
      const deltaStart = performance.now();
      await act(async () => root.render(<NewTabScreen {...props} template={r.screen as never} snapshot={changed} />));
      const delta = performance.now() - deltaStart;
      drawn = container.querySelectorAll("*").length;
      act(() => root.unmount());
      container.remove();
      if (run === 0) continue; // warm-up
      mounts.push(mounted);
      deltas.push(delta);
    }
    if (pass === 0) continue;
    console.log(
      `BENCH ${JSON.stringify({ measure: "mount", id, screen: r.screen, domNodes: drawn, mountReads, deltaReads, mountMs: stats(mounts), deltaMs: stats(deltas), n: MOUNTS, sessions: sessions.length })}`,
    );
  }
  expect(true).toBe(true);
}, 600_000);
