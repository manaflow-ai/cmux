// l10n-allow-file: test fixture names, not shipped UI.
// Session Info's sections move by drag and stay where they were put (Leo, 2026-10-29: "LITERALLY BE
// THE EXACT SAME FUCKING SITUTAION AS BEFORE BUT NOW YOU CAN FUCKING FCLICK AND DRAG TO REARRANGE").
// - Its default layout does not change by accident: the three blocks and their sections, in order,
//   are pinned here (the gallery's full chat, every section shown). A change to them changes this test.
// - Dragging a section's six-dot handle past a neighbour's middle moves it there, anywhere in the
//   panel, across blocks too (Leo, 2026-10-31: "THE CLICK DRAG" ... "WHERE IS MY FUCKING PARITY");
//   the order is saved on release and Escape puts it back. Up and Down Arrow on the handle move it
//   one place, across a block's edge too, and the handle keeps focus.
// - A hairline (a block's start) sits wherever two adjacent sections come from different blocks.
// - The order is kept (localStorage) and read again by a fresh panel; another pane's drag reaches
//   this one through the `storage` event; the per-block order #27291 saved is read as one order.
// session-info-section-order-browser.test.tsx checks in Chromium that the handles draw nothing until hover.
import { afterAll, beforeEach, expect, test } from "bun:test";
import { JSDOM, VirtualConsole } from "jsdom";
import { teardownDom } from "./support/domTeardown";

const dom = new JSDOM("<!doctype html><html><body><main id=root></main></body></html>", {
  url: "http://localhost/",
  pretendToBeVisual: true,
  virtualConsole: new VirtualConsole(),
});
const scope = globalThis as Record<string, unknown>;
const replacements: Record<string, unknown> = {
  window: dom.window,
  document: dom.window.document,
  navigator: dom.window.navigator,
  Node: dom.window.Node,
  HTMLElement: dom.window.HTMLElement,
  Element: dom.window.Element,
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
  localStorage: dom.window.localStorage,
  addEventListener: dom.window.addEventListener.bind(dom.window),
  removeEventListener: dom.window.removeEventListener.bind(dom.window),
  getComputedStyle: dom.window.getComputedStyle.bind(dom.window),
  requestAnimationFrame: dom.window.requestAnimationFrame.bind(dom.window),
  cancelAnimationFrame: dom.window.cancelAnimationFrame.bind(dom.window),
  IS_REACT_ACT_ENVIRONMENT: true,
};
for (const key of Object.getOwnPropertyNames(dom.window))
  if (/^(HTML|SVG|CSS|Shadow|Document|Mutation|Keyboard|Mouse|Focus|Event|Storage)/.test(key) && !(key in scope))
    replacements[key] = (dom.window as unknown as Record<string, unknown>)[key];
const saved = Object.keys(replacements).map((key) => [key, key in scope, scope[key]] as const);
Object.assign(scope, replacements);

const { act, createElement } = await import("react");
const { createRoot } = await import("react-dom/client");
const { setPaneLanguage, translate } = await import("../src/agent-session/acpmux/i18n");
const { SessionInfo } = await import("../src/agent-session/acpmux/session-info/SessionInfo");
const { resetSessionInfoState } = await import("../src/agent-session/acpmux/session-info/sessionInfoState");
const { ORDER_KEY, parseOrder, resetSectionOrderForTests } =
  await import("../src/agent-session/acpmux/session-info/sectionOrder");
const gallery = (await import("../src/agent-session/acpmux/session-info/SessionInfo.gallery")).default;
type SessionInfoProps = import("react").ComponentProps<typeof SessionInfo>;

afterAll(async () => {
  setPaneLanguage("en");
  await teardownDom(saved, { window: dom.window, scope });
});
setPaneLanguage("en");

// Show more open: every section drawn, the line among them.
const full = { ...(gallery.variants.full!.props as SessionInfoProps), more: true };

beforeEach(() => {
  dom.window.localStorage.clear();
  resetSectionOrderForTests();
  resetSessionInfoState();
});

async function mount(props: SessionInfoProps = full) {
  const container = dom.window.document.createElement("main");
  dom.window.document.body.replaceChildren(container);
  const root = createRoot(container);
  await act(async () => root.render(createElement(SessionInfo, props)));
  return { container, root };
}

/// The slots in the order drawn: each section's id, and `more` for the Show more line.
const order = (container: HTMLElement) =>
  [...container.querySelectorAll<HTMLElement>(".acpmux-session-info-sections > [data-slot]")].map((slot) => {
    const id = slot.querySelector<HTMLElement>(":scope > section[data-section]")?.dataset.section ?? "more";
    expect(slot.dataset.slot).toBe(id);
    return id;
  });
const layout = order;

const handle = (container: HTMLElement, id: string) =>
  container.querySelector<HTMLButtonElement>(`section[data-section="${id}"] > .acpmux-session-info-section__handle`)!;
const slotOf = (container: HTMLElement, id: string) => container.querySelector<HTMLElement>(`[data-slot="${id}"]`)!;

/// Lays the sections out top to bottom at the given heights, in the order drawn (jsdom has no layout).
function stack(container: HTMLElement, heights: Record<string, number>) {
  for (const [id, height] of Object.entries(heights)) {
    const slot = container.querySelector<HTMLElement>(`[data-slot="${id}"]`);
    if (slot) Object.defineProperty(slot, "offsetHeight", { configurable: true, get: () => height });
  }
  for (const slot of container.querySelectorAll<HTMLElement>("[data-slot]"))
    Object.defineProperty(slot, "offsetTop", {
      configurable: true,
      get() {
        let top = 0;
        for (
          let prior = slot.previousElementSibling as HTMLElement | null;
          prior;
          prior = prior.previousElementSibling as HTMLElement | null
        )
          top += heights[prior.dataset.slot!] ?? 28;
        return top;
      },
    });
}

const pointer = (type: string, clientY: number) =>
  new dom.window.MouseEvent(type, { bubbles: true, cancelable: true, button: 0, clientY });

// Leo, 2026-11-03: "1. Machines showing up so I know if it's cloud or not 2. context 3.
// Subagents/background tasks running 4. Sources". Then Outputs, the Show more line, and under it the
// pull requests, Usage and Connectors (Lucas, 2026-11-05, Session Info lab).
const DEFAULT = [
  "environment",
  "context",
  "subagents",
  "tasks",
  "sources",
  "outputs",
  "more",
  "changes",
  "usage",
  "connectors",
];
const HEIGHTS = {
  more: 28,
  environment: 100,
  context: 28,
  usage: 28,
  connectors: 28,
  changes: 120,
  sources: 80,
  outputs: 60,
  subagents: 90,
  tasks: 70,
};

test("the default layout: the machine, Context, what it runs, then Sources, in order", async () => {
  const { container, root } = await mount();
  expect(layout(container)).toEqual(DEFAULT);
  // Environment is pinned first and has no handle (sectionOrder.ts PINNED_TOP): its rows start with
  // their own icons, and a grip beside them read as a stray icon.
  const environment = container.querySelector<HTMLElement>('section[data-section="environment"]')!;
  expect(environment.querySelector(".acpmux-session-info-section__handle")).toBeNull();
  // A handle is the only thing each other section gained, first in it, and it takes no text.
  for (const section of container.querySelectorAll<HTMLElement>("section[data-section]")) {
    if (section.dataset.section === "environment") continue;
    const first = section.firstElementChild as HTMLElement;
    expect(first.className).toBe("acpmux-session-info-section__handle");
    expect(first.textContent).toBe("");
    expect(first.getAttribute("aria-label")).toBe(
      translate("sessionInfo.reorderSection", { section: section.getAttribute("aria-label")! }),
    );
  }
  expect(dom.window.localStorage.getItem(ORDER_KEY)).toBeNull();
  await act(async () => root.unmount());
});

test("a section drags anywhere, lifted while held, and the order stays", async () => {
  const { container, root } = await mount();
  stack(container, HEIGHTS);
  // Tops: environment 0, context 100, subagents 128, tasks 218, sources 288, outputs 368. Grab Outputs
  // and carry its top to 140: past Subagents' middle (173), not Context's (114).
  await act(async () => handle(container, "outputs").dispatchEvent(pointer("pointerdown", 380)));
  expect(slotOf(container, "outputs").hasAttribute("data-lifted")).toBe(true);
  expect(container.querySelector('section[data-section="outputs"]')!.hasAttribute("data-dragging")).toBe(true);
  await act(async () => dom.window.dispatchEvent(pointer("pointermove", 152)));
  expect(order(container)).toEqual([
    "environment",
    "context",
    "outputs",
    "subagents",
    "tasks",
    "sources",
    "more",
    "changes",
    "usage",
    "connectors",
  ]);
  // Nothing is saved until the drop.
  expect(dom.window.localStorage.getItem(ORDER_KEY)).toBeNull();
  // The section is drawn under the pointer, whatever its place: 368 + (152 - 380) - its new top 128.
  expect(slotOf(container, "outputs").style.transform).toBe("translateY(12px)");
  await act(async () => dom.window.dispatchEvent(pointer("pointerup", 152)));
  expect(container.querySelector("[data-lifted]")).toBeNull();
  expect(container.querySelector("[data-dragging]")).toBeNull();
  expect(slotOf(container, "outputs").style.transform).toBe("");
  // The saved order is the drawn one, the line included, with Progress (no plan here) and Also working
  // here (no other chat here) in their slots, neither drawn.
  expect(
    (JSON.parse(dom.window.localStorage.getItem(ORDER_KEY)!) as string[]).filter(
      (id) => id !== "progress" && id !== "alsoHere",
    ),
  ).toEqual(order(container));
  await act(async () => root.unmount());

  // A fresh page reads the saved order.
  resetSectionOrderForTests();
  const again = await mount();
  expect(order(again.container).slice(0, 4)).toEqual(["environment", "context", "outputs", "subagents"]);
  await act(async () => again.root.unmount());
});

test("a section dragged under a closed Show more line folds away on the drop", async () => {
  const { container, root } = await mount({ ...full, more: false });
  expect(order(container)).toEqual(DEFAULT.slice(0, DEFAULT.indexOf("more") + 1));
  stack(container, HEIGHTS);
  // Outputs (top 368) carried down past the line's middle (442): it is drawn while held, then tucks.
  await act(async () => handle(container, "outputs").dispatchEvent(pointer("pointerdown", 380)));
  await act(async () => dom.window.dispatchEvent(pointer("pointermove", 430)));
  expect(order(container).slice(-2)).toEqual(["more", "outputs"]);
  await act(async () => dom.window.dispatchEvent(pointer("pointerup", 430)));
  expect(order(container)).not.toContain("outputs");
  const saved = JSON.parse(dom.window.localStorage.getItem(ORDER_KEY)!) as string[];
  expect(saved.indexOf("outputs")).toBeGreaterThan(saved.indexOf("more"));
  await act(async () => root.unmount());
});

test("Escape during a drag puts the section back and saves nothing", async () => {
  const { container, root } = await mount();
  stack(container, HEIGHTS);
  await act(async () => handle(container, "tasks").dispatchEvent(pointer("pointerdown", 230)));
  await act(async () => dom.window.dispatchEvent(pointer("pointermove", 10)));
  // Carried above Environment, it lands right under it: Environment stays first.
  expect(order(container).slice(0, 2)).toEqual(["environment", "tasks"]);
  await act(async () => {
    dom.window.dispatchEvent(new dom.window.KeyboardEvent("keydown", { key: "Escape", bubbles: true }));
  });
  expect(layout(container)).toEqual(DEFAULT);
  expect(container.querySelector("[data-lifted]")).toBeNull();
  expect(dom.window.localStorage.getItem(ORDER_KEY)).toBeNull();
  // The drag is over: a later move moves nothing.
  await act(async () => dom.window.dispatchEvent(pointer("pointermove", 10)));
  expect(layout(container)).toEqual(DEFAULT);
  await act(async () => root.unmount());
});

test("a section taller than the panel still drags to the first place under Environment", async () => {
  const { container, root } = await mount();
  // Sources expanded far past the panel's height: its middle can never reach the top.
  stack(container, { ...HEIGHTS, sources: 2000 });
  // Sources' top is 288; the pointer goes from its handle to the panel's top edge.
  await act(async () => handle(container, "sources").dispatchEvent(pointer("pointerdown", 300)));
  await act(async () => dom.window.dispatchEvent(pointer("pointermove", 14)));
  expect(order(container).slice(0, 2)).toEqual(["environment", "sources"]);
  await act(async () => dom.window.dispatchEvent(pointer("pointerup", 14)));
  expect((JSON.parse(dom.window.localStorage.getItem(ORDER_KEY)!) as string[]).slice(0, 2)).toEqual([
    "environment",
    "sources",
  ]);
  await act(async () => root.unmount());
});

test("an arrow key during a pointer drag changes nothing, so Escape still restores the order", async () => {
  const { container, root } = await mount();
  stack(container, HEIGHTS);
  await act(async () => handle(container, "tasks").dispatchEvent(pointer("pointerdown", 230)));
  await act(async () => {
    const up = new dom.window.KeyboardEvent("keydown", { key: "ArrowUp", bubbles: true });
    handle(container, "tasks").dispatchEvent(up);
  });
  expect(dom.window.localStorage.getItem(ORDER_KEY)).toBeNull();
  await act(async () => {
    dom.window.dispatchEvent(new dom.window.KeyboardEvent("keydown", { key: "Escape", bubbles: true }));
  });
  expect(layout(container)).toEqual(DEFAULT);
  expect(dom.window.localStorage.getItem(ORDER_KEY)).toBeNull();
  await act(async () => root.unmount());
});

test("Up and Down Arrow on a handle move the section one place, across the Show more line, keeping focus", async () => {
  const { container, root } = await mount();
  const key = (id: string, name: string) =>
    act(async () => {
      handle(container, id).dispatchEvent(new dom.window.KeyboardEvent("keydown", { key: name, bubbles: true }));
    });
  handle(container, "subagents").focus();
  await key("subagents", "ArrowUp");
  expect(order(container).slice(0, 3)).toEqual(["environment", "subagents", "context"]);
  expect(dom.window.document.activeElement).toBe(handle(container, "subagents"));
  await key("subagents", "ArrowDown");
  expect(layout(container)).toEqual(DEFAULT);
  // Outputs steps under the line, and back.
  await key("outputs", "ArrowDown");
  expect(order(container).slice(5, 7)).toEqual(["more", "outputs"]);
  await key("outputs", "ArrowUp");
  expect(layout(container)).toEqual(DEFAULT);
  // Already first under the pinned Environment, or last: it stays.
  await key("context", "ArrowUp");
  await key("connectors", "ArrowDown");
  expect(layout(container)).toEqual(DEFAULT);
  await act(async () => root.unmount());
});

test("the per-block order #27291 saved is read as one order, nothing lost", async () => {
  dom.window.localStorage.setItem(
    ORDER_KEY,
    JSON.stringify({ about: ["context", "environment", "connectors"], made: ["outputs", "changes"] }),
  );
  const { container, root } = await mount();
  // The blocks one after another (Usage after Context, Sources after Changes, as they follow by
  // default); then, saved before the line, the less-used sections go under it in that order.
  // Environment is pinned first; the rest keep the saved order.
  expect(layout(container)).toEqual([
    "environment",
    "context",
    "outputs",
    "sources",
    "subagents",
    "tasks",
    "more",
    "usage",
    "connectors",
    "changes",
  ]);
  // Unchanged storage until the person moves something; then the one order.
  expect(JSON.parse(dom.window.localStorage.getItem(ORDER_KEY)!)).toHaveProperty("about");
  await act(async () => {
    handle(container, "tasks").dispatchEvent(
      new dom.window.KeyboardEvent("keydown", { key: "ArrowUp", bubbles: true }),
    );
  });
  expect(JSON.parse(dom.window.localStorage.getItem(ORDER_KEY)!)).toEqual([
    "environment",
    "context",
    "outputs",
    "sources",
    "progress",
    "tasks",
    "subagents",
    "alsoHere",
    "more",
    "usage",
    "connectors",
    "changes",
  ]);
  await act(async () => root.unmount());
});

test("parseOrder keeps known sections once and reads both shapes", () => {
  expect(parseOrder(null)).toEqual([]);
  expect(parseOrder("not json")).toEqual([]);
  expect(parseOrder(JSON.stringify(["tasks", "bogus", "tasks", "context"]))).toEqual(["tasks", "context"]);
  expect(parseOrder(JSON.stringify({ running: ["tasks", "subagents"] }))).toEqual([
    "environment",
    "context",
    "usage",
    "connectors",
    "changes",
    "sources",
    "outputs",
    "progress",
    "tasks",
    "alsoHere",
    "subagents",
  ]);
  expect(parseOrder(JSON.stringify({ about: 3 }))).toEqual([]);
});

test("another pane's drag reaches this one", async () => {
  const { container, root } = await mount();
  const value = JSON.stringify(["outputs", "environment"]);
  dom.window.localStorage.setItem(ORDER_KEY, value);
  await act(async () => {
    dom.window.dispatchEvent(new dom.window.StorageEvent("storage", { key: ORDER_KEY, newValue: value }));
  });
  // A section the saved order lacks takes the place after the one it follows by default: Context after
  // Environment, Subagents after Context (Progress, not drawn, between), the line's sections after it.
  // Environment is pinned first, so Outputs lands right under it.
  expect(order(container)).toEqual([
    "environment",
    "outputs",
    "context",
    "subagents",
    "tasks",
    "sources",
    "more",
    "changes",
    "usage",
    "connectors",
  ]);
  await act(async () => root.unmount());
});

test("a panel closed while another pane reorders shows that order when it opens again", async () => {
  const first = await mount();
  await act(async () => first.root.unmount());
  // Another pane's drag, while no panel here listens.
  const moved = [
    "environment",
    "tasks",
    "context",
    "sources",
    "outputs",
    "subagents",
    "more",
    "usage",
    "connectors",
    "changes",
  ];
  dom.window.localStorage.setItem(ORDER_KEY, JSON.stringify(moved));
  const again = await mount();
  expect(order(again.container)).toEqual(moved);
  await act(async () => again.root.unmount());
});

test("an order storage refused stays when the panel opens again", async () => {
  const first = await mount();
  const setItem = dom.window.Storage.prototype.setItem;
  dom.window.Storage.prototype.setItem = () => {
    throw new Error("QuotaExceededError");
  };
  try {
    await act(async () => {
      handle(first.container, "tasks").dispatchEvent(
        new dom.window.KeyboardEvent("keydown", { key: "ArrowUp", bubbles: true }),
      );
    });
    expect(order(first.container).slice(2, 4)).toEqual(["tasks", "subagents"]);
    await act(async () => first.root.unmount());
    const again = await mount();
    expect(order(again.container).slice(2, 4)).toEqual(["tasks", "subagents"]);
    await act(async () => again.root.unmount());
  } finally {
    dom.window.Storage.prototype.setItem = setItem;
  }
});

test("a hidden section keeps its slot when the shown ones move", async () => {
  // No background work: Background tasks is not shown.
  const quiet = {
    ...full,
    processes: [],
    transcriptTasks: [],
    workflows: [],
    made: { ...full.made!, scheduled: [] },
  } as SessionInfoProps;
  const { container, root } = await mount(quiet);
  expect(order(container)).not.toContain("tasks");
  await act(async () => {
    handle(container, "subagents").dispatchEvent(
      new dom.window.KeyboardEvent("keydown", { key: "ArrowUp", bubbles: true }),
    );
  });
  // Background tasks, hidden, keeps its slot after the place Subagents left.
  expect(JSON.parse(dom.window.localStorage.getItem(ORDER_KEY)!)).toEqual([
    "environment",
    "subagents",
    "progress",
    "context",
    "tasks",
    "sources",
    "outputs",
    "alsoHere",
    "more",
    "changes",
    "usage",
    "connectors",
  ]);
  await act(async () => root.unmount());
});
