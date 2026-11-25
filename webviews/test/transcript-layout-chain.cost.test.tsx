// l10n-allow-file: the transcript fixture text is test data, not shipped UI.
// A transcript's layout pass keeps nothing of the pass before it once the next one is placed (VirtualTranscript.tsx
// `measured`). A closure in that pass that named the last pass (`last`) put it in the pass's scope, which the placed
// layout's index closures keep: each layout kept the one before it and its rows, so a chat open for a long stream
// kept every snapshot it was ever shown (the transcript-replay bench's god log: 117 MB of JS heap after GC against
// 40 MB, cmux#47373). Leo, 2026-11-24 (ask-2e5d6a3cb2): "im assuming there's maybe a slight limit maybe higher than
// 1.2x but idk i also feel like we should be able to get it efficient... idk if we just somehow happened to not
// encounter the blankness before or of there was a regression or if somehow we hti the point where it's just
// becoming blank?"
import { afterAll, expect, test } from "bun:test";
import { JSDOM, VirtualConsole } from "jsdom";
import type { AcpmuxRow } from "../src/agent-session/acpmux/model";
import { installJsdomScroller } from "./support/jsdomScroller";
import { settleReact } from "./support/domTeardown";

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
  // Reports each element it is given, as a browser's first delivery does: the rows' drawn heights reach the
  // layout (`drawn`), so it is placed through the indexed pass a real pane runs, not the estimate alone.
  ResizeObserver: class {
    constructor(private readonly callback: (entries: object[], observer: unknown) => void) {}
    observe(target: Element) {
      const size = { inlineSize: 760, blockSize: 72 };
      const contentRect = { x: 0, y: 0, top: 0, left: 0, right: 760, bottom: 72, width: 760, height: 72 };
      queueMicrotask(() =>
        this.callback([{ target, contentRect, borderBoxSize: [size], contentBoxSize: [size] }], this),
      );
    }
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
const hadComputerUseHook = "cmuxAcpmuxComputerUseState" in scope;

Object.defineProperty(dom.window.HTMLElement.prototype, "clientWidth", { configurable: true, get: () => 760 });
installJsdomScroller(dom.window as never, () => 600);
// A drawn row is 72 px tall: its height is read by getBoundingClientRect (transcript/drawnHeight.ts).
const realRect = dom.window.HTMLElement.prototype.getBoundingClientRect;
dom.window.HTMLElement.prototype.getBoundingClientRect = function (this: HTMLElement) {
  if (!this.dataset.rowId) return realRect.call(this);
  return { x: 0, y: 0, top: 0, left: 0, right: 760, bottom: 72, width: 760, height: 72, toJSON() {} } as DOMRect;
};

const { act } = await import("react");
const { createRoot } = await import("react-dom/client");
const { VirtualTranscript } = await import("../src/agent-session/acpmux/App");

afterAll(async () => {
  await settleReact();
  dom.window.close();
  for (const [key, had, value] of saved) {
    if (had) scope[key] = value;
    else delete scope[key];
  }
  if (!hadComputerUseHook) delete scope.cmuxAcpmuxComputerUseState;
});

const row = (id: string, kind: string, text?: string): AcpmuxRow => ({ id, kind, text, version: 1, at: 1 });
const turn = (index: number): AcpmuxRow[] => [
  row(`t${index}-user`, "user", `Question ${index}`),
  row(`t${index}-answer`, "assistant", `Answer ${index}.\n\nWith a second paragraph so the turn has height.`),
  { ...row(`t${index}-end`, "turnSummary"), status: "completed", durationMs: 1_000 } as AcpmuxRow,
];
const nextFrame = () => new Promise<void>((resolve) => dom.window.requestAnimationFrame(() => resolve()));

test("a streamed chat's layout passes keep no earlier snapshot of its rows", async () => {
  const root = createRoot(dom.window.document.getElementById("root")!);
  const render = (rows: AcpmuxRow[]) =>
    act(async () => {
      root.render(
        <VirtualTranscript rows={rows} sessionId="session-1" onToggleActivity={() => {}} expanded={new Set()} />,
      );
      await nextFrame();
      await nextFrame();
    });
  const PASSES = 40;
  const shown: WeakRef<readonly AcpmuxRow[]>[] = [];
  try {
    let rows: AcpmuxRow[] = [];
    for (let pass = 0; pass < PASSES; pass += 1) {
      // A new snapshot each pass, as the pane gives one per streamed record: the rows are new objects too, so a
      // kept snapshot is its own rows, not a shared prefix.
      rows = [...rows.map((each) => ({ ...each })), ...turn(pass)];
      if (pass < PASSES - 4) shown.push(new WeakRef(rows));
      await render(rows);
    }
    for (let pass = 0; pass < 4; pass += 1) {
      // A turn of the event loop between collections: a WeakRef holds its target until the job ends.
      await new Promise((resolve) => setImmediate(resolve));
      Bun.gc(true);
    }
    // A pass or two of React's own (the committed and the work-in-progress fiber) may still hold one.
    expect(shown.filter((ref) => ref.deref() !== undefined).length).toBeLessThanOrEqual(2);
  } finally {
    await act(async () => root.unmount());
  }
});
