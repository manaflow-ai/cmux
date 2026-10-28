// The prompt rail on either edge (Leo, 2026-10-22: "also we can add an option for moving it the
// right.. maybe specifically right clicking that area (and as a toggle) it can happen"). Right-clicking
// the rail opens a menu whose one item moves it to the other edge and back; the choice is the
// cmux.json key agentPane.display.rail.side, written through the host and read back from its
// `display` event, so it persists. On the right the preview card opens on the rail's left.
import { afterAll, expect, test } from "bun:test";
import { JSDOM, VirtualConsole } from "jsdom";
import type { AcpmuxRow } from "../src/agent-session/acpmux/model";
import { turnView } from "../src/agent-session/acpmux/conversation/turns";
// The compact rail; the full-height map reads the same side (ScrollMap.tsx).
(globalThis as { cmuxExperiments?: Record<string, string> }).cmuxExperiments = { "thread-minimap-layout": "compact" };

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

// jsdom has no layout: a 600 px viewport (the transcript's first height) over a long conversation,
// and a scroll offset the test moves as the reader would.
const VIEWPORT = 600;
let paneWidth = 1040;
Object.defineProperty(dom.window.HTMLElement.prototype, "clientHeight", { configurable: true, get: () => VIEWPORT });
// Wide enough for the minimap's gutter (ThreadMinimap MIN_GUTTER).
Object.defineProperty(dom.window.HTMLElement.prototype, "clientWidth", { configurable: true, get: () => paneWidth });
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
const { chatDisplay, registerChatDisplayHost, setChatDisplay, RAIL_SIDE_KEY } =
  await import("../src/agent-session/acpmux/chatDisplay");

afterAll(() => {
  registerChatDisplayHost(undefined);
  setChatDisplay({});
  dom.window.close();
  for (const [key, had, value] of saved) {
    if (had) scope[key] = value;
    else delete scope[key];
  }
  delete (globalThis as { cmuxExperiments?: Record<string, string> }).cmuxExperiments;
});

const document = dom.window.document;
const row = (id: string, kind: string, text?: string): AcpmuxRow => ({ id, kind, text, version: 1, at: 1 });
const turns = Array.from({ length: 12 }, (_, index) => [
  row(`user-${index + 1}`, "user", `Question ${index}`),
  row(`t${index}-answer`, "assistant", `Answer ${index}.\n\nWith a second paragraph so the turn has height.`),
  { ...row(`t${index}-end`, "turnSummary"), status: "completed", durationMs: 1_000 },
]).flat();

const rail = () => document.querySelector<HTMLElement>("nav.acpmux-minimap__rail")!;
const tick = (index: number) => document.querySelector<HTMLElement>(`[data-tick="${index}"]`)!;
const menuItems = () => [...document.querySelectorAll<HTMLElement>('[role="menuitem"]')];
/// Right-clicks tick `index` and picks the menu's item, checking its label first.
async function move(index: number, label: string) {
  await act(async () => {
    tick(index).dispatchEvent(
      new dom.window.MouseEvent("contextmenu", { bubbles: true, cancelable: true, clientX: 20, clientY: 40 }),
    );
  });
  const items = menuItems();
  expect(items.map((item) => item.textContent)).toEqual([label]);
  await act(async () => items[0]!.click());
  expect(menuItems()).toHaveLength(0);
}
/// The host's next write (the page sends it 250 ms after the change).
let wrote: (entry: [string, unknown]) => void = () => {};
const nextWrite = () => new Promise<[string, unknown]>((resolve) => (wrote = resolve));

test.each(["compact", "full"])(
  "right-clicking the %s rail moves it to the right edge and back, and the host keeps the choice",
  async (arm) => {
    registerChatDisplayHost((key, value) => wrote([key, value]));
    setChatDisplay({ "agentPane.display.minimap": arm });
    const root = createRoot(document.getElementById("root")!);
    try {
      await act(async () =>
        root.render(
          <VirtualTranscript
            rows={turnView(turns, new Set())}
            sessionId="rail-side"
            onToggleActivity={() => {}}
            expanded={new Set()}
          />,
        ),
      );
      // The current base places the left rail beside the text: 120 px in this viewport.
      expect(rail().dataset.side).toBe("left");
      expect(rail().style.left).toBe("120px");
      expect(rail().style.right).toBe("");

      let written = nextWrite();
      await move(3, "Move to Right Edge");
      expect(chatDisplay().railSide).toBe("right");
      expect(rail().dataset.side).toBe("right");
      expect(rail().style.right).toBe("16px");
      expect(rail().style.left).toBe("");
      expect(await written).toEqual([RAIL_SIDE_KEY, "right"]);

      // The card opens on the rail's left: it draws outside the scroller (PreviewCard.tsx), counted
      // from an anchor at the rail box's top-right corner, its right edge 52 px in from it.
      await act(async () => tick(5).focus());
      const card = document.querySelector<HTMLElement>(".acpmux-minimap__card")!;
      expect(card).not.toBeNull();
      const anchor = document.querySelector<HTMLElement>(".acpmux-minimap__anchor")!;
      expect(anchor.style.right).toBe("0px");
      expect(anchor.style.left).toBe("auto");
      expect(card.style.transform).toMatch(/^translate3d\(-52px, .*\) translateX\(-100%\)$/);
      await act(async () => tick(5).blur());

      // And back: the key goes, so the default holds again.
      written = nextWrite();
      await move(3, "Move to Left Edge");
      expect(rail().dataset.side).toBe("left");
      expect(rail().style.left).toBe("120px");
      expect(await written).toEqual([RAIL_SIDE_KEY, null]);

      // The host's own event (cmux.json, Settings, another pane's menu) moves it too.
      await act(async () => setChatDisplay({ "agentPane.display.minimap": arm, [RAIL_SIDE_KEY]: "right" }));
      expect(rail().dataset.side).toBe("right");
      // A value the setting does not offer is the default.
      await act(async () => setChatDisplay({ "agentPane.display.minimap": arm, [RAIL_SIDE_KEY]: "top" }));
      expect(rail().dataset.side).toBe("left");
    } finally {
      await act(async () => root.unmount());
    }
  },
);

// The current base allows the left rail to overlap the text by at most 8px. A right rail's
// fixed 16px inset needs 44px of gutter for that same limit, rather than the left rail's 28px.
for (const arm of ["compact", "full"]) {
  for (const width of [780, 800, 808])
    test(`${arm}: a right rail at pane width ${width} never takes more than 8px of transcript input`, async () => {
      paneWidth = width;
      setChatDisplay({ "agentPane.display.minimap": arm, [RAIL_SIDE_KEY]: "right" });
      const root = createRoot(document.getElementById("root")!);
      try {
        await act(async () =>
          root.render(
            <VirtualTranscript
              rows={turnView(turns, new Set())}
              sessionId="rail-side-room"
              onToggleActivity={() => {}}
              expanded={new Set()}
            />,
          ),
        );
        const rail = document.querySelector<HTMLElement>(".acpmux-minimap__rail");
        if (width < 808) expect(rail === null).toBe(true);
        else {
          expect(rail).not.toBeNull();
          expect(rail!.style.right).toBe("16px");
        }
      } finally {
        await act(async () => root.unmount());
        paneWidth = 1040;
        setChatDisplay({});
      }
    });

  test(`${arm}: the left rail remains available at pane width 780`, async () => {
    paneWidth = 780;
    setChatDisplay({ "agentPane.display.minimap": arm });
    const root = createRoot(document.getElementById("root")!);
    try {
      await act(async () =>
        root.render(
          <VirtualTranscript
            rows={turnView(turns, new Set())}
            sessionId="rail-left-room"
            onToggleActivity={() => {}}
            expanded={new Set()}
          />,
        ),
      );
      expect(document.querySelector(".acpmux-minimap__rail")).not.toBeNull();
    } finally {
      await act(async () => root.unmount());
      paneWidth = 1040;
      setChatDisplay({});
    }
  });
}
