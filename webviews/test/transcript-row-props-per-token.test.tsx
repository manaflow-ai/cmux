// A streamed token changes the live row alone. The transcript must work out and compare the frame
// props of that row only, not of every mounted row: a god chat's short turns mount about 60 rows and
// a long-turn chat about 30, and per-row work on each token made the god chat's tokens cost more
// (Leo, 2026-11-04: "never ... acceptable ... linear time growth degradation"). Each frame whose props
// React compares on a token counts here (`sameRowFrame`, RowFrame's memo comparator): a frame kept
// whole is skipped without one.
import { afterAll, expect, mock, test } from "bun:test";
import { JSDOM, VirtualConsole } from "jsdom";
import type { AcpmuxRow } from "../src/agent-session/acpmux/model";
import { teardownDom } from "./support/domTeardown";

const dom = new JSDOM("<!doctype html><div id=root></div>", {
  url: "http://localhost/",
  pretendToBeVisual: true,
  virtualConsole: new VirtualConsole(),
});
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
  requestAnimationFrame: dom.window.requestAnimationFrame.bind(dom.window),
  cancelAnimationFrame: dom.window.cancelAnimationFrame.bind(dom.window),
  IS_REACT_ACT_ENVIRONMENT: true,
};
for (const key of Object.getOwnPropertyNames(dom.window))
  if (/^(HTML|SVG|CSS|Shadow|Document|Mutation)/.test(key) && !(key in scope))
    replacements[key] = (dom.window as unknown as Record<string, unknown>)[key];
const saved = Object.keys(replacements).map((key) => [key, key in scope, scope[key]] as const);
Object.assign(scope, replacements);

// The view's height sets how many rows mount: each test draws at its own.
let viewport = 600;
Object.defineProperty(dom.window.HTMLElement.prototype, "clientHeight", { configurable: true, get: () => viewport });
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
// jsdom has no layout: every row draws 40px tall.
const ROW_HEIGHT = 40;
dom.window.HTMLElement.prototype.getBoundingClientRect = function (this: HTMLElement) {
  const height = this.dataset.rowId ? ROW_HEIGHT : 0;
  return { x: 0, y: 0, top: 0, left: 0, right: 0, bottom: height, width: 0, height, toJSON() {} } as DOMRect;
};

let compared = 0;
const MODEL = "../src/agent-session/acpmux/virtualTranscriptModel";
const real = await import(MODEL);
const realSameRowFrame = real.sameRowFrame;
void mock.module(MODEL, () => ({
  ...real,
  sameRowFrame: (previous: Record<string, unknown>, next: Record<string, unknown>) => {
    compared += 1;
    return realSameRowFrame(previous, next);
  },
}));

const { act } = await import("react");
const { createRoot } = await import("react-dom/client");
const { VirtualTranscript } = await import("../src/agent-session/acpmux/App");

afterAll(async () => {
  await teardownDom(saved, { window: dom.window, scope });
});

let at = 0;
const row = (id: string, kind: string, extra: Partial<AcpmuxRow> = {}): AcpmuxRow => ({
  id,
  kind,
  version: 1,
  at: (at += 1_000),
  ...extra,
});
const Plain = ({ row }: { row: AcpmuxRow }) => <p>{row.text}</p>;
const registry = { user: Plain, assistant: Plain } as unknown as Parameters<typeof VirtualTranscript>[0]["registry"];

const TOKENS = 10;

/// Streams TOKENS tokens into the live reply under a view `height` tall: the rows mounted, and the
/// frames compared per token.
async function streamAt(height: number): Promise<{ mounted: number; perToken: number }> {
  viewport = height;
  const history = Array.from({ length: 120 }, (_, index) => [
    row(`h${height}-${index}-user`, "user", { text: `Question ${index}` }),
    row(`h${height}-${index}-answer`, "assistant", { text: `Answer ${index}.` }),
  ]).flat();
  let reply = row(`h${height}-live`, "assistant", { text: "First words", streaming: true });
  const root = createRoot(dom.window.document.getElementById("root")!);
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
    await draw();
    const mounted = dom.window.document.querySelectorAll(".acpmux-row").length;
    compared = 0;
    for (let step = 1; step <= TOKENS; step += 1) {
      reply = { ...reply, version: reply.version + 1, text: `${reply.text} word${step}` };
      await draw();
    }
    return { mounted, perToken: compared / TOKENS };
  } finally {
    await act(async () => root.unmount());
  }
}

test("a streamed token compares no more frames with twice the rows mounted", async () => {
  const few = await streamAt(200);
  const many = await streamAt(650);
  console.log(
    `PER-UPDATE frames compared: ${few.perToken} with ${few.mounted} rows mounted, ${many.perToken} with ${many.mounted}`,
  );
  // The second view really mounts about twice the rows (about 30 and 60, as a god chat and a long-turn chat do).
  expect(many.mounted).toBeGreaterThanOrEqual(few.mounted * 1.6);
  // The live row and the row over it (whose next drawn row is the live one), for each render a token takes:
  // never the rows in view. Before, every mounted frame was compared on every render.
  expect(many.perToken).toBeLessThanOrEqual(4);
  expect(few.perToken).toBeLessThanOrEqual(4);
});
