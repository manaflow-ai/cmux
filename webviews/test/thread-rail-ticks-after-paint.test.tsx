// Goal chat-attach-p95: a chat's open drew the rail's ticks in the commit that first drew its newest
// message, about 180 of them, and about 200 more in the commit after (bench/chat-open.bench.ts
// PROFILE=1). The rail now draws at once as one spacer as tall as all its rows, and its ticks come in
// the frame after that first paint: the open's commit mounts no tick, and the rail's height stays.
import { afterAll, expect, test } from "bun:test";
import { JSDOM, VirtualConsole } from "jsdom";
import type { AcpmuxRow } from "../src/agent-session/acpmux/model";
import { turnView } from "../src/agent-session/acpmux/conversation/turns";
import { teardownDom } from "./support/domTeardown";
(globalThis as { cmuxExperiments?: Record<string, string> }).cmuxExperiments = {
  "thread-minimap-layout": "compact",
};

const dom = new JSDOM("<!doctype html><div id=root></div>", {
  url: "http://localhost/",
  pretendToBeVisual: true,
  virtualConsole: new VirtualConsole(),
});
/// Frames run only when the test paints them.
const frames = new Map<number, (time: number) => void>();
let nextFrame = 1;
const scope = globalThis as Record<string, unknown>;
const replacements: Record<string, unknown> = {
  window: dom.window,
  document: dom.window.document,
  navigator: dom.window.navigator,
  HTMLElement: dom.window.HTMLElement,
  Element: dom.window.Element,
  customElements: dom.window.customElements,
  Node: dom.window.Node,
  MutationObserver: dom.window.MutationObserver,
  IntersectionObserver: class {
    observe() {}
    unobserve() {}
    disconnect() {}
  },
  ResizeObserver: class {
    observe() {}
    unobserve() {}
    disconnect() {}
  },
  requestAnimationFrame: (run: (time: number) => void) => {
    const id = nextFrame++;
    frames.set(id, run);
    return id;
  },
  cancelAnimationFrame: (id: number) => frames.delete(id),
  IS_REACT_ACT_ENVIRONMENT: true,
};
for (const key of Object.getOwnPropertyNames(dom.window))
  if (/^(HTML|SVG|CSS|Shadow|Document|Mutation)/.test(key) && !(key in scope))
    replacements[key] = (dom.window as unknown as Record<string, unknown>)[key];
const saved = Object.keys(replacements).map((key) => [key, key in scope, scope[key]] as const);
Object.assign(scope, replacements);
dom.window.requestAnimationFrame = replacements.requestAnimationFrame as typeof dom.window.requestAnimationFrame;
dom.window.cancelAnimationFrame = replacements.cancelAnimationFrame as typeof dom.window.cancelAnimationFrame;

Object.defineProperty(dom.window.HTMLElement.prototype, "clientHeight", {
  configurable: true,
  get: () => 600,
});
Object.defineProperty(dom.window.HTMLElement.prototype, "clientWidth", {
  configurable: true,
  get: () => 1040,
});
const offsets = new WeakMap<object, number>();
Object.defineProperty(dom.window.HTMLElement.prototype, "scrollTop", {
  configurable: true,
  get(this: object) {
    return offsets.get(this) ?? 0;
  },
  set(this: object, value: number) {
    offsets.set(this, value);
  },
});

const { act } = await import("react");
const { createRoot } = await import("react-dom/client");
const { VirtualTranscript } = await import("../src/agent-session/acpmux/App");

afterAll(async () => {
  await teardownDom(saved, { window: dom.window, scope });
  delete (globalThis as { cmuxExperiments?: Record<string, string> }).cmuxExperiments;
});

/// Runs the frames due now (one browser frame), then the tasks they queued.
const paint = () =>
  act(async () => {
    const due = [...frames.values()];
    frames.clear();
    for (const run of due) run(performance.now());
    for (let turn = 0; turn < 5; turn++) await new Promise((resolve) => setTimeout(resolve, 0));
  });

const row = (id: string, kind: string, text?: string): AcpmuxRow => ({
  id,
  kind,
  text,
  version: 1,
  at: 1,
});
const chat = (session: string, count: number) =>
  Array.from({ length: count }, (_, index) => [
    row(`${session}-t${index}-user`, "user", `Question ${index}`),
    row(`${session}-t${index}-answer`, "assistant", `Answer ${index}.\n\nWith a second paragraph.`),
    {
      ...row(`${session}-t${index}-end`, "turnSummary"),
      status: "completed",
      durationMs: 1_000,
    },
  ]).flat();

const TURNS = 12;
const ticks = () => dom.window.document.querySelectorAll(".acpmux-minimap__tick").length;
/// The list's rows' height: drawn rows at the rail's pitch, spacers as tall as their style says.
const listHeight = () => {
  const list = dom.window.document.querySelector<HTMLElement>(".acpmux-minimap__list")!;
  const pitch = Number.parseFloat(list.style.getPropertyValue("--acpmux-minimap-pitch"));
  return [...list.children].reduce(
    (sum, child) =>
      sum + (child.querySelector("[data-tick]") ? pitch : Number.parseFloat((child as HTMLElement).style.height) || 0),
    0,
  );
};

test("a chat's open mounts no tick; its ticks come in the frame after, the rail as tall all along", async () => {
  const root = createRoot(dom.window.document.getElementById("root")!);
  const view = (session: string) => (
    <VirtualTranscript
      rows={turnView(chat(session, TURNS), new Set())}
      sessionId={session}
      onToggleActivity={() => {}}
      expanded={new Set()}
    />
  );
  try {
    await act(async () => root.render(view("chat-a")));
    // The open's commit: the rail and its list are there, every row a spacer.
    expect(dom.window.document.querySelector(".acpmux-minimap__list")).not.toBeNull();
    expect(ticks()).toBe(0);
    const before = listHeight();
    expect(before).toBeGreaterThan(0);
    await paint();
    expect(ticks()).toBe(TURNS);
    expect(listHeight()).toBe(before);

    // A switch to another chat defers its ticks the same way.
    await act(async () => root.render(view("chat-b")));
    expect(ticks()).toBe(0);
    await paint();
    expect(ticks()).toBe(TURNS);
  } finally {
    await act(async () => root.unmount());
  }
});
