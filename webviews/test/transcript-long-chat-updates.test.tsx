// A long chat's snapshots redo only what changed after the first changed row (the turn view, the
// layout and the drawn-height placement keep the rest). Whatever arrives, the transcript must draw
// as if it had laid the chat out from scratch: each mounted row right below the one above it, by
// that row's drawn height, and turns shaped as a fresh look at the same rows shapes them.
import { afterAll, expect, test } from "bun:test";
import { JSDOM, VirtualConsole } from "jsdom";
import type { AcpmuxRow } from "../src/agent-session/acpmux/model";
import { type TurnView, turnView, turnViewFrom } from "../src/agent-session/acpmux/conversation/turns";
import { minimapTurns } from "../src/agent-session/acpmux/threadMinimap/model";

const dom = new JSDOM("<!doctype html><div id=root></div>", {
  url: "http://localhost/",
  pretendToBeVisual: true,
  virtualConsole: new VirtualConsole(),
});
const scope = globalThis as Record<string, unknown>;
// Each element's ResizeObserver callback, which the test fires as a redrawn row would.
const observers = new Map<Element, (entries: { target: Element }[]) => void>();
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
    constructor(private readonly callback: (entries: { target: Element }[]) => void) {}
    observe(target: Element) {
      observers.set(target, this.callback);
    }
    unobserve(target: Element) {
      observers.delete(target);
    }
    disconnect() {}
  },
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
Object.defineProperty(dom.window.HTMLElement.prototype, "clientHeight", { configurable: true, get: () => VIEWPORT });
Object.defineProperty(dom.window.HTMLElement.prototype, "clientWidth", { configurable: true, get: () => 760 });
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
// jsdom has no layout: each row draws at a height of its own, which a redraw can change.
const drawnHeights = new Map<string, number>();
const drawnHeight = (id: string) => drawnHeights.get(id) ?? 40 + (id.length % 7) * 9;
dom.window.HTMLElement.prototype.getBoundingClientRect = function (this: HTMLElement) {
  const height = this.dataset.rowId ? drawnHeight(this.dataset.rowId) : 0;
  return { x: 0, y: 0, top: 0, left: 0, right: 0, bottom: height, width: 0, height, toJSON() {} } as DOMRect;
};

const { act } = await import("react");
const { createRoot } = await import("react-dom/client");
const { VirtualTranscript } = await import("../src/agent-session/acpmux/App");

afterAll(() => {
  dom.window.close();
  for (const [key, had, value] of saved) {
    if (had) scope[key] = value;
    else delete scope[key];
  }
});

let at = 0;
const row = (id: string, kind: string, extra: Partial<AcpmuxRow> = {}): AcpmuxRow => ({
  id,
  kind,
  version: 1,
  at: (at += 1_000),
  ...extra,
});
const finishedTurn = (index: number) => [
  row(`t${index}-user`, "user", { text: `Question ${index}` }),
  row(`t${index}-read`, "activity", {
    items: [{ kind: "tool", text: "", tool: { id: `read-${index}`, title: "Read a file", status: "completed" } }],
  }),
  row(`t${index}-answer`, "assistant", { text: `Answer ${index}.\n\nWith a second paragraph.` }),
  row(`t${index}-end`, "turnSummary", { status: "completed", durationMs: 1_000 }),
];

/// The mounted rows, top to bottom: each must sit right below the row above it, by that one's drawn
/// height. A fast scroll mounts separate runs of rows, so only rows next to each other are compared.
function placement() {
  const rows = [...dom.window.document.querySelectorAll<HTMLElement>(".acpmux-row")].map((node) => ({
    id: node.dataset.rowId!,
    index: Number(node.getAttribute("aria-posinset")),
    // Less the thread's top padding.
    top: Number.parseFloat(node.style.top) + (Number.parseFloat(node.style.marginTop) || 0) - 16,
  }));
  rows.sort((a, b) => a.index - b.index);
  const pairs = rows
    .slice(1)
    .flatMap((next, index) =>
      next.index === rows[index]!.index + 1
        ? [{ id: next.id, gap: Math.round((next.top - rows[index]!.top - drawnHeight(rows[index]!.id)) * 100) / 100 }]
        : [],
    );
  // The view's rows are always mounted together, so an empty list means nothing was compared.
  expect(pairs.length).toBeGreaterThan(0);
  return pairs;
}

/// The same rows as new objects, so nothing is reused from an earlier look at them.
const fresh = (rows: AcpmuxRow[]) => rows.map((one) => structuredClone(one));

test("a long chat draws each update as a fresh layout would: streaming, redraws, scrolling, a turn ending", async () => {
  const history = Array.from({ length: 300 }, (_, index) => {
    // Turn 150 comes two hours after the one before it, so a date line draws over it.
    if (index === 150) at += 7_200_000;
    return finishedTurn(index);
  }).flat();
  const prompt = row("live-user", "user", { text: "Stream a long answer" });
  let reply = row("live-answer", "assistant", { text: "First words", streaming: true });
  const raw = () => [...history, prompt, reply];
  const root = createRoot(dom.window.document.getElementById("root")!);
  const expanded = new Set<string>();
  // Each snapshot's turns build on the last one's, as the pane's do.
  let view: TurnView | undefined;
  const draw = async (rows: AcpmuxRow[], working: boolean) => {
    view = turnViewFrom(rows, expanded, { working, now: at }, view);
    const shown = view.rows;
    // The turns read as a fresh look at the same rows does.
    expect(shown.map((one) => [one.id, one.version])).toEqual(
      turnView(fresh(rows), new Set(), { working, now: at }).map((one) => [one.id, one.version]),
    );
    await act(async () =>
      root.render(<VirtualTranscript rows={shown} working={working} onToggleActivity={() => {}} expanded={expanded} />),
    );
  };
  const redraw = async (id: string, height: number) => {
    drawnHeights.set(id, height);
    const node = dom.window.document.querySelector(`[data-row-id="${id}"]`)!;
    await act(async () => observers.get(node)?.([{ target: node }]));
  };
  try {
    await draw(raw(), true);
    expect(placement().filter((entry) => entry.gap !== 0)).toEqual([]);
    const scroller = dom.window.document.querySelector<HTMLElement>(".acpmux-scroll")!;

    // The reply streams in at the latest message, growing as it is drawn.
    for (let step = 1; step <= 5; step += 1) {
      reply = { ...reply, version: reply.version + 1, text: `${reply.text} and more words, step ${step}.` };
      await draw(raw(), true);
      await redraw("live-answer", 60 + step * 30);
      expect(placement().filter((entry) => entry.gap !== 0)).toEqual([]);
    }

    // The reader scrolls up into the history while it streams; a row there draws taller.
    scroller.scrollTop = 6_000;
    await act(async () => void scroller.dispatchEvent(new dom.window.Event("scroll")));
    const mounted = dom.window.document.querySelectorAll<HTMLElement>(".acpmux-row");
    const middle = mounted[Math.floor(mounted.length / 2)]!.dataset.rowId!;
    await redraw(middle, 333);
    reply = { ...reply, version: reply.version + 1, text: `${reply.text} Still streaming.` };
    await draw(raw(), true);
    expect(placement().filter((entry) => entry.gap !== 0)).toEqual([]);

    // A prompt sent while it streams waits in the turn; an answer far up the history is edited.
    const held = row("held-user", "user", { text: "And then?", pending: true });
    await draw([...raw(), held], true);
    history[402] = { ...history[402]!, version: 2, text: "Answer 100, corrected." };
    await draw([...raw(), held], true);
    expect(placement().filter((entry) => entry.gap !== 0)).toEqual([]);

    // The turn ends: its work folds under "Worked for", below a summary.
    reply = { ...reply, version: reply.version + 1, streaming: false };
    history.push(prompt, reply, row("live-end", "turnSummary", { status: "completed", durationMs: 9_000 }));
    await draw(history, false);
    expect(placement().filter((entry) => entry.gap !== 0)).toEqual([]);
    scroller.scrollTop = 1e9;
    await act(async () => void scroller.dispatchEvent(new dom.window.Event("scroll")));
    expect(placement().filter((entry) => entry.gap !== 0)).toEqual([]);
  } finally {
    await act(async () => root.unmount());
  }
});

test("a new row registry places the whole chat again: rows not drawn yet take its estimate", async () => {
  const rows = turnView(Array.from({ length: 300 }, (_, index) => finishedTurn(index)).flat(), new Set());
  // A customization replaces the registry; its rows estimate taller before they are drawn.
  const Tall = Object.assign(() => <div>tall</div>, { measure: () => 500 });
  const registry = { assistant: Tall, user: Tall } as unknown as Parameters<typeof VirtualTranscript>[0]["registry"];
  const spacer = (host: Element) => parseFloat(host.querySelector<HTMLElement>(".acpmux-spacer")!.style.height);
  const transcript = (withRegistry: boolean) => (
    <VirtualTranscript
      rows={rows}
      working={false}
      registry={withRegistry ? registry : undefined}
      onToggleActivity={() => {}}
      expanded={new Set()}
    />
  );
  const host = dom.window.document.getElementById("root")!;
  const root = createRoot(host);
  try {
    await act(async () => root.render(transcript(false)));
    const before = spacer(host);
    await act(async () => root.render(transcript(true)));
    // 600 prompts and answers, most off screen, now estimate at 500 points each instead of about
    // 100 (rows already drawn keep their drawn heights).
    expect(spacer(host)).toBeGreaterThan(before + 400 * 400);
  } finally {
    await act(async () => root.unmount());
  }
});

test("a late answer that lands before the next prompt previews in its own turn's minimap entry", () => {
  const answered = [
    row("m0-user", "user", { text: "First" }),
    row("m0-read", "activity"),
    row("m1-user", "user", { text: "Second" }),
    row("m1-answer", "assistant", { text: "Second answer" }),
  ];
  const before = minimapTurns(answered, "s");
  const late = [
    ...answered.slice(0, 2),
    row("m0-answer", "assistant", { text: "Late first answer" }),
    ...answered.slice(2),
  ];
  expect(minimapTurns(late, "s", before).turns).toEqual(minimapTurns(late, "s").turns);
});
