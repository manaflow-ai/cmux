// l10n-allow-file: test fixture prompts and replies, not shipped UI.
// Placement follows drawn state; one settle (cmuxterm-hq docs/design/transcript-motion-model.md rules
// 5 and 8, step 1). A height drawn with a row open never places the row once it is closed (or the
// other way): it left a hole between activity rows (Leo, 2026-11-17: "why is there this big gap when
// i have shit expanded"). And every motion's end settles the rows: no row keeps an inline translate,
// and every mounted row is read again.
import { afterAll, expect, mock, test } from "bun:test";
import { JSDOM, VirtualConsole } from "jsdom";
import type { AcpmuxRow, RowHeights } from "../src/agent-session/acpmux/model";
import type { FollowChase } from "../src/agent-session/acpmux/conversation/followChase";
import { installJsdomScroller } from "./support/jsdomScroller";
import { teardownDom } from "./support/domTeardown";

const dom = new JSDOM("<!doctype html><div id=root></div>", {
  url: "http://localhost/",
  pretendToBeVisual: true,
  virtualConsole: new VirtualConsole(),
});
dom.window.document.documentElement.dataset.agentMotion = "off";

type Observed = { callback: (entries: ResizeObserverEntry[]) => void; targets: Set<Element> };
const observers: Observed[] = [];
class RecordingResizeObserver {
  private readonly observed: Observed;
  constructor(callback: (entries: ResizeObserverEntry[]) => void) {
    this.observed = { callback, targets: new Set() };
    observers.push(this.observed);
  }
  observe(target: Element) {
    this.observed.targets.add(target);
  }
  unobserve(target: Element) {
    this.observed.targets.delete(target);
  }
  disconnect() {
    this.observed.targets.clear();
  }
}

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
  ResizeObserver: RecordingResizeObserver,
  requestAnimationFrame: dom.window.requestAnimationFrame.bind(dom.window),
  cancelAnimationFrame: dom.window.cancelAnimationFrame.bind(dom.window),
  IS_REACT_ACT_ENVIRONMENT: true,
};
for (const key of Object.getOwnPropertyNames(dom.window))
  if (/^(HTML|SVG|CSS|Shadow|Document|Mutation)/.test(key) && !(key in scope))
    replacements[key] = (dom.window as unknown as Record<string, unknown>)[key];
const saved = Object.keys(replacements).map((key) => [key, key in scope, scope[key]] as const);
Object.assign(scope, replacements);

const VIEWPORT = 600;
Object.defineProperty(dom.window.HTMLElement.prototype, "clientWidth", { configurable: true, get: () => 760 });
installJsdomScroller(dom.window as never, () => VIEWPORT);
const sized = new WeakMap<Element, number>();
const rect = (height: number) =>
  ({ top: 0, bottom: height, left: 0, right: 760, width: 760, height, x: 0, y: 0, toJSON() {} }) as DOMRect;
dom.window.HTMLElement.prototype.getBoundingClientRect = function (this: HTMLElement) {
  return rect(sized.get(this) ?? 0);
};
dom.window.HTMLElement.prototype.getClientRects = function (this: HTMLElement) {
  const height = sized.get(this);
  return (height === undefined ? [] : [rect(height)]) as unknown as DOMRectList;
};

// The transcript's follow chase, kept so the test can bring it to rest; the real chase runs.
const chases: FollowChase[] = [];
const FOLLOW_CHASE = "../src/agent-session/acpmux/conversation/followChase";
const realChase = { ...(await import(FOLLOW_CHASE)) };
const realCreate =
  realChase.createFollowChase as typeof import("../src/agent-session/acpmux/conversation/followChase").createFollowChase;
await mock.module(FOLLOW_CHASE, () => ({
  ...realChase,
  createFollowChase: (...args: Parameters<typeof realCreate>) => {
    const chase = realCreate(...args);
    chases.push(chase);
    return chase;
  },
}));

const { act } = await import("react");
const { createRoot } = await import("react-dom/client");
const { VirtualTranscript } = await import("../src/agent-session/acpmux/App");
const { turnView } = await import("../src/agent-session/acpmux/conversation/turns");
const { layoutConversation } = await import("../src/agent-session/acpmux/model");
const { setMessageOpened } = await import("../src/agent-session/acpmux/conversation/incomingOpened");
const { drawnOpenStateHolds, rowOpenState } = await import("../src/agent-session/acpmux/conversation/rowOpenState");
const { DisclosureSession, callDisclosureKey, useTranscriptDisclosure } =
  await import("../src/agent-session/acpmux/conversation/transcriptDisclosureModel");

afterAll(async () => {
  await teardownDom(saved, { window: dom.window, scope });
});

const row = (id: string, kind: string, text?: string): AcpmuxRow => ({ id, kind, text, version: 1, at: 1 });

test("a height drawn open places the row only while it is open; closed, the row is placed at its closed height", () => {
  const session = "drawn-open-state";
  const message = row("m1", "assistant", "A reply from another agent.");
  const rows = [row("u1", "user", "Question"), message];
  // Measured open: the signature it was drawn with.
  setMessageOpened(session, message.id, true);
  const drawnOpen = { height: 480, open: rowOpenState(session, message) };
  // Out of the mounted range nothing measures it again: open, the drawn height places it.
  expect(drawnOpenStateHolds(drawnOpen, session, message, false)).toBe(true);
  // A remembered estimate taken open, at the height drawn open.
  const known: RowHeights = new WeakMap();
  layoutConversation(rows, 700, new Map(), undefined, known, undefined, session);
  const keptOpen = known.get(message)!;
  expect(keptOpen.open).toBe(drawnOpen.open);
  known.set(message, { ...keptOpen, height: drawnOpen.height });
  const open = layoutConversation(rows, 700, new Map(), undefined, known, undefined, session);
  expect(open.heights[1]).toBe(480);

  // Closed: neither the drawn height nor the estimate taken open places it.
  setMessageOpened(session, message.id, false);
  expect(rowOpenState(session, message)).not.toBe(drawnOpen.open);
  expect(drawnOpenStateHolds(drawnOpen, session, message, false)).toBe(false);
  // A mounted row is measured in the state it is drawn in before the frame paints: its drawn height holds.
  expect(drawnOpenStateHolds(drawnOpen, session, message, true)).toBe(true);
  const closed = layoutConversation(rows, 700, new Map(), undefined, known, undefined, session);
  const fresh = layoutConversation(rows, 700, new Map(), undefined, new WeakMap(), undefined, session);
  expect(closed.heights[1]).not.toBe(480);
  expect(closed.heights[1]).toBe(fresh.heights[1]!);
  // And the estimate taken closed is kept with the closed signature.
  expect(known.get(message)!.open).toBe(rowOpenState(session, message));
  setMessageOpened(session, message.id, false);
});

test("a disclosure choice on a row's call changes its signature", async () => {
  const session = "drawn-open-choice";
  const run = { ...row("run1", "activity"), items: [{ tool: { id: "call-7" } }] } as unknown as AcpmuxRow;
  let setOpen: ((open: boolean) => void) | undefined;
  function Call() {
    const [, set] = useTranscriptDisclosure(callDisclosureKey("call-7"));
    setOpen = set;
    return null;
  }
  const host = dom.window.document.createElement("div");
  dom.window.document.body.appendChild(host);
  const root = createRoot(host);
  try {
    await act(async () =>
      root.render(
        <DisclosureSession.Provider value={session}>
          <Call />
        </DisclosureSession.Provider>,
      ),
    );
    const before = rowOpenState(session, run);
    await act(async () => setOpen!(true));
    const opened = rowOpenState(session, run);
    expect(opened).not.toBe(before);
    await act(async () => setOpen!(false));
    expect(rowOpenState(session, run)).not.toBe(opened);
  } finally {
    await act(async () => root.unmount());
    host.remove();
  }
});

test("after a motion comes to rest no row keeps an inline translate, and every mounted row is read", async () => {
  observers.length = 0;
  chases.length = 0;
  const turns = Array.from({ length: 3 }, (_, index) => [
    row(`t${index}-user`, "user", `Question ${index}`),
    row(`t${index}-answer`, "assistant", `Answer ${index}.`),
    { ...row(`t${index}-end`, "turnSummary"), status: "completed", durationMs: 1_000 },
  ]).flat();
  const root = createRoot(dom.window.document.getElementById("root")!);
  try {
    await act(async () =>
      root.render(
        <VirtualTranscript rows={turnView(turns, new Set())} onToggleActivity={() => {}} expanded={new Set()} />,
      ),
    );
    await act(() => new Promise<void>((resolve) => dom.window.requestAnimationFrame(() => resolve())));
    const thread = dom.window.document.querySelector<HTMLElement>(".acpmux-thread")!;
    const rows = [...thread.querySelectorAll<HTMLElement>(":scope > .acpmux-row")];
    expect(rows.length).toBeGreaterThan(2);
    const chase = chases.at(-1)!;
    expect(chase).toBeDefined();
    // A motion left rows drawn off their places, and one row's height changed under it unreported.
    for (const node of rows) node.style.translate = "0 12px";
    rows[0]!.style.transform = "translateY(4px)";
    const answer = thread.querySelector<HTMLElement>('.acpmux-row[data-row-id="t1-answer"]')!;
    const spacer = dom.window.document.querySelector<HTMLElement>(".acpmux-scroll > .acpmux-spacer")!;
    const before = spacer.style.height;
    sized.set(answer, 700);
    await act(async () => {
      chase.carry(thread, 30);
      expect(thread.style.translate).not.toBe("");
      // The chase comes to rest: its end settles the rows (after it, once).
      chase.stop();
      await Promise.resolve();
      await Promise.resolve();
    });
    for (const node of thread.querySelectorAll<HTMLElement>(":scope > .acpmux-row")) {
      expect(node.style.translate).toBe("");
      expect(node.style.transform).toBe("");
    }
    expect(thread.style.translate).toBe("");
    // The row whose height changed under the motion is placed at it, read by the settle.
    expect(spacer.style.height).not.toBe(before);
  } finally {
    await act(async () => root.unmount());
  }
});
