// l10n-allow-file: test fixture prompts, answers and tool titles, not shipped UI.
// Opening or closing anything in the transcript never moves the reader's view (Leo 2026-10-20:
// "Expanding/collapsing any tool call or collapsible must NOT scroll the user's view: anchor the
// clicked row in place"). Followed to the latest row, opening the last turn's "Worked for" used to
// put the view at the new latest row, so the line the reader clicked jumped up by everything it
// opened. jsdom has no layout: a row is drawn at its translateY, and an element in it at the row's
// top less the scroller's offset.
import { afterAll, expect, test } from "bun:test";
import { JSDOM, VirtualConsole } from "jsdom";
import type { AcpmuxRow } from "../src/agent-session/acpmux/model";
import { turnView, WORKED } from "../src/agent-session/acpmux/conversation/turns";

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
// Pierre's registered elements read their own DOM constructors at import time.
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
const scroller = () => dom.window.document.querySelector<HTMLElement>(".acpmux-scroll")!;
/// Where an element in a row is drawn in the viewport: its row's place less the offset. Rows report
/// no drawn height (0 is "not laid out"), so they place by their estimates.
dom.window.HTMLElement.prototype.getBoundingClientRect = function (this: HTMLElement) {
  const row = this.closest<HTMLElement>(".acpmux-row");
  const at = row ? Number(/translateY\(([-\d.]+)px\)/.exec(row.style.transform)?.[1] ?? 0) : 0;
  const top = row ? at - (scroller()?.scrollTop ?? 0) : 0;
  return { top, bottom: top, left: 0, right: 0, width: 0, height: 0, x: 0, y: top, toJSON() {} } as DOMRect;
};

// The page's clock, which the test moves on past a hold (foldAnchor.ts) instead of waiting it out.
const clock = performance.now.bind(performance);
let skew = 0;
performance.now = () => clock() + skew;

const { act } = await import("react");
const { createRoot } = await import("react-dom/client");
const { VirtualTranscript } = await import("../src/agent-session/acpmux/App");

afterAll(() => {
  performance.now = clock;
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
const call = (id: string) => ({
  kind: "tool",
  text: "",
  tool: { id, title: `Read src/${id}.ts`, kind: "read", status: "completed", output: `contents of ${id}` },
});
/// A turn that worked before it answered: its "Worked for" line opens to the calls.
const turn = (index: number) => [
  row(`t${index}-user`, "user", { text: `Question ${index}` }),
  row(`t${index}-run`, "activity", { items: Array.from({ length: 8 }, (_, step) => call(`t${index}-${step}`)) }),
  row(`t${index}-answer`, "assistant", { text: `Answer ${index}.\n\nWith a second paragraph so the turn has height.` }),
  row(`t${index}-end`, "turnSummary", { status: "completed", toolCount: 8 }),
];
const source = Array.from({ length: 12 }, (_, index) => turn(index)).flat();
const workedId = (index: number) => `${WORKED}-t${index}-user`;

/// The transcript as the pane draws it: a click on "Worked for" toggles it in `expanded`.
function mount(initial: Set<string>) {
  const root = createRoot(dom.window.document.getElementById("root")!);
  let expanded = initial;
  const render = () =>
    root.render(
      <VirtualTranscript
        rows={turnView(source, expanded)}
        sessionId="session-1"
        expanded={expanded}
        onToggleActivity={(id) => {
          const next = new Set(expanded);
          if (next.has(id)) next.delete(id);
          else next.add(id);
          expanded = next;
          render();
        }}
      />,
    );
  return { root, render };
}
const line = (index: number) =>
  dom.window.document.querySelector<HTMLElement>(`[data-row-id="${workedId(index)}"] button.cv-worked`)!;
const latest = () =>
  parseFloat(dom.window.document.querySelector<HTMLElement>(".acpmux-spacer")!.style.height) - VIEWPORT;

test("opening the last turn's Worked for while the view follows the latest row leaves the line where it was clicked", async () => {
  const { root, render } = mount(new Set());
  try {
    await act(async () => render());
    // Followed: the view rests at the latest row, the last turn's line in view.
    expect(scroller().scrollTop).toBe(latest());
    const before = line(11).getBoundingClientRect().top;
    expect(before).toBeGreaterThan(0);
    expect(before).toBeLessThan(VIEWPORT);
    const end = latest();

    await act(async () => line(11).click());
    expect(line(11).getAttribute("aria-expanded")).toBe("true");
    // The calls opened under the line; the line did not move, and the view no longer sits at the
    // (now further down) latest row.
    expect(line(11).getBoundingClientRect().top).toBe(before);
    expect(latest()).toBeGreaterThan(end);
    expect(scroller().scrollTop).toBeLessThan(latest());

    // A snapshot after the hold (here the same rows drawn again) does not pull the view back down.
    skew += 10_000;
    await act(async () => render());
    expect(line(11).getBoundingClientRect().top).toBe(before);
  } finally {
    await act(async () => root.unmount());
  }
});

test("closing an open Worked for scrolled up the transcript leaves its line where it was clicked", async () => {
  const { root, render } = mount(new Set([workedId(8)]));
  /// The reader scrolls to `top` (a wheel, then the browser's scroll event).
  const scrollTo = async (top: number) => {
    await act(async () => {
      scroller().dispatchEvent(new dom.window.Event("wheel"));
      scroller().scrollTop = top;
      scroller().dispatchEvent(new dom.window.Event("scroll"));
    });
  };
  try {
    await act(async () => render());
    // Up the transcript until turn 8's open line is drawn, then with it 200 px down the view.
    for (let top = latest(); !line(8) && top > 0; top -= VIEWPORT / 2) await scrollTo(top);
    await scrollTo(scroller().scrollTop + line(8).getBoundingClientRect().top - 200);
    const before = line(8).getBoundingClientRect().top;
    expect(before).toBe(200);
    expect(scroller().scrollTop).toBeLessThan(latest() - VIEWPORT);

    await act(async () => line(8).click());
    expect(line(8).getAttribute("aria-expanded")).toBe("false");
    expect(line(8).getBoundingClientRect().top).toBe(before);
  } finally {
    await act(async () => root.unmount());
  }
});
