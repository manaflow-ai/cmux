// A streaming reply changes only the latest row. The rows above it keep their props, so they must
// not draw again on every token: a long chat would otherwise redo every mounted row's markdown per
// snapshot. Each row's renderer counts its renders here.
import { afterAll, expect, test } from "bun:test";
import { JSDOM, VirtualConsole } from "jsdom";
import type { AcpmuxRow } from "../src/agent-session/acpmux/model";

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

const renders = new Map<string, number>();
const Counting = ({ row }: { row: AcpmuxRow }) => {
  renders.set(row.id, (renders.get(row.id) ?? 0) + 1);
  return <p>{row.text}</p>;
};
const registry = { user: Counting, assistant: Counting, turnSummary: Counting } as unknown as Parameters<
  typeof VirtualTranscript
>[0]["registry"];

test("a streaming update that changes only the latest row draws no earlier row again", async () => {
  const history = Array.from({ length: 20 }, (_, index) => [
    row(`t${index}-user`, "user", { text: `Question ${index}` }),
    row(`t${index}-answer`, "assistant", { text: `Answer ${index}.` }),
  ]).flat();
  let reply = row("live-answer", "assistant", { text: "First words", streaming: true });
  const root = createRoot(dom.window.document.getElementById("root")!);
  // The pane keeps these across snapshots (its expanded state and toggleActivity callback).
  const expanded = new Set<string>();
  const onToggleActivity = () => {};
  const draw = async () =>
    act(async () =>
      root.render(
        <VirtualTranscript
          rows={[...history, reply]}
          working
          registry={registry}
          onToggleActivity={onToggleActivity}
          expanded={expanded}
        />,
      ),
    );
  try {
    await draw();
    const earlier = [...dom.window.document.querySelectorAll<HTMLElement>(".acpmux-row")]
      .map((node) => node.dataset.rowId!)
      .filter((id) => id !== "live-answer");
    expect(earlier.length).toBeGreaterThan(2);
    renders.clear();
    for (let step = 1; step <= 5; step += 1) {
      reply = { ...reply, version: reply.version + 1, text: `${reply.text} and more, step ${step}.` };
      await draw();
    }
    expect(renders.get("live-answer") ?? 0).toBeGreaterThanOrEqual(5);
    expect(earlier.filter((id) => renders.has(id)).map((id) => [id, renders.get(id)])).toEqual([]);
  } finally {
    await act(async () => root.unmount());
  }
});

// The hover reveal of a turn's footer is cached by the row under the pointer. A footer that appears,
// or stops being the last turn's, while the pointer rests on that turn must still show on the next
// pointer move inside the same row.
test("a turn's footer shows on hover after the rows change under a resting pointer", async () => {
  const root = createRoot(dom.window.document.getElementById("root")!);
  const expanded = new Set<string>();
  const onToggleActivity = () => {};
  const draw = async (rows: AcpmuxRow[], working: boolean) =>
    act(async () =>
      root.render(
        <VirtualTranscript
          rows={rows}
          working={working}
          registry={registry}
          onToggleActivity={onToggleActivity}
          expanded={expanded}
        />,
      ),
    );
  const node = (id: string) => dom.window.document.querySelector<HTMLElement>(`.acpmux-row[data-row-id="${id}"]`);
  const hover = async (id: string) =>
    act(async () => {
      node(id)!.dispatchEvent(new dom.window.MouseEvent("pointerover", { bubbles: true }));
    });
  const first = [row("h-user", "user", { text: "Do it" }), row("h-answer", "assistant", { text: "Working" })];
  try {
    await draw(first, true);
    await hover("h-answer");
    const done = [...first, row("h-summary", "turnSummary")];
    await draw(
      [...done, row("h2-user", "user", { text: "Next" }), row("h2-answer", "assistant", { text: "On it" })],
      true,
    );
    expect(node("h-summary")).not.toBeNull();
    await hover("h-answer");
    expect(node("h-summary")!.hasAttribute("data-turn-revealed")).toBe(true);
  } finally {
    await act(async () => root.unmount());
  }
});
