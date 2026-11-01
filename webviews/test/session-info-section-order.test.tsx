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

afterAll(() => {
  setPaneLanguage("en");
  dom.window.close();
  for (const [key, had, value] of saved) {
    if (had) scope[key] = value;
    else delete scope[key];
  }
});
setPaneLanguage("en");

const full = gallery.variants.full!.props as SessionInfoProps;

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

/// The runs of one block's sections, in the order drawn: a new run starts at each hairline.
const layout = (container: HTMLElement) => {
  const runs: { group: string; sections: string[] }[] = [];
  for (const slot of container.querySelectorAll<HTMLElement>(".acpmux-session-info-sections > [data-slot]")) {
    const id = slot.querySelector<HTMLElement>(":scope > section[data-section]")!.dataset.section!;
    expect(slot.dataset.slot).toBe(id);
    if (runs.length === 0 || slot.hasAttribute("data-run-start"))
      runs.push({ group: slot.dataset.group!, sections: [] });
    runs[runs.length - 1]!.sections.push(id);
  }
  return runs;
};
const order = (container: HTMLElement) => layout(container).flatMap((run) => run.sections);

const handle = (container: HTMLElement, id: string) =>
  container.querySelector<HTMLButtonElement>(`section[data-section="${id}"] > .acpmux-session-info-section__handle`)!;
const slotOf = (container: HTMLElement, id: string) => container.querySelector<HTMLElement>(`[data-slot="${id}"]`)!;

/// Lays the sections out top to bottom at the given heights, in the order drawn (jsdom has no layout).
function stack(container: HTMLElement, heights: Record<string, number>) {
  for (const [id, height] of Object.entries(heights))
    Object.defineProperty(slotOf(container, id), "offsetHeight", { configurable: true, get: () => height });
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

const DEFAULT = [
  { group: "about", sections: ["environment", "context", "connectors"] },
  { group: "made", sections: ["changes", "sources", "outputs"] },
  { group: "running", sections: ["subagents", "tasks"] },
];
const HEIGHTS = {
  environment: 100,
  context: 28,
  connectors: 28,
  changes: 120,
  sources: 80,
  outputs: 60,
  subagents: 90,
  tasks: 70,
};

test("the default layout: three blocks and their sections, in order", async () => {
  const { container, root } = await mount();
  expect(layout(container)).toEqual(DEFAULT);
  // A handle is the only thing each section gained, first in it, and it takes no text.
  for (const section of container.querySelectorAll<HTMLElement>("section[data-section]")) {
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

test("a section drags into another block, lifted while held, and the order stays", async () => {
  const { container, root } = await mount();
  stack(container, HEIGHTS);
  // Grab Outputs (top 356) and carry it up past Context's middle (114) into where it runs.
  await act(async () => handle(container, "outputs").dispatchEvent(pointer("pointerdown", 400)));
  expect(slotOf(container, "outputs").hasAttribute("data-lifted")).toBe(true);
  expect(container.querySelector('section[data-section="outputs"]')!.hasAttribute("data-dragging")).toBe(true);
  // It looks for its place 24px below its top, 356 - 260 + 24 = 120: below Context's middle (114),
  // above Connectors' (142).
  await act(async () => dom.window.dispatchEvent(pointer("pointermove", 140)));
  expect(order(container)).toEqual([
    "environment",
    "context",
    "outputs",
    "connectors",
    "changes",
    "sources",
    "subagents",
    "tasks",
  ]);
  // Its block shows by the hairlines around it; nothing is saved until the drop.
  expect(layout(container)).toEqual([
    { group: "about", sections: ["environment", "context"] },
    { group: "made", sections: ["outputs"] },
    { group: "about", sections: ["connectors"] },
    { group: "made", sections: ["changes", "sources"] },
    { group: "running", sections: ["subagents", "tasks"] },
  ]);
  expect(dom.window.localStorage.getItem(ORDER_KEY)).toBeNull();
  // The section is drawn under the pointer, whatever its place: 356 + (140 - 400) - its new top 128.
  expect(slotOf(container, "outputs").style.transform).toBe("translateY(-32px)");
  await act(async () => dom.window.dispatchEvent(pointer("pointerup", 140)));
  expect(container.querySelector("[data-lifted]")).toBeNull();
  expect(container.querySelector("[data-dragging]")).toBeNull();
  expect(slotOf(container, "outputs").style.transform).toBe("");
  expect(JSON.parse(dom.window.localStorage.getItem(ORDER_KEY)!)).toEqual(order(container));
  await act(async () => root.unmount());

  // A fresh page reads the saved order.
  resetSectionOrderForTests();
  const again = await mount();
  expect(order(again.container).slice(0, 4)).toEqual(["environment", "context", "outputs", "connectors"]);
  await act(async () => again.root.unmount());
});

test("Escape during a drag puts the section back and saves nothing", async () => {
  const { container, root } = await mount();
  stack(container, HEIGHTS);
  await act(async () => handle(container, "tasks").dispatchEvent(pointer("pointerdown", 580)));
  await act(async () => dom.window.dispatchEvent(pointer("pointermove", 10)));
  expect(order(container)[0]).toBe("tasks");
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

test("a section taller than the panel still drags above the first one", async () => {
  const { container, root } = await mount();
  // Sources expanded far past the panel's height: its middle can never reach the top.
  stack(container, { ...HEIGHTS, sources: 2000 });
  // Sources' top is 276; the pointer goes from its handle to the panel's top edge.
  await act(async () => handle(container, "sources").dispatchEvent(pointer("pointerdown", 290)));
  await act(async () => dom.window.dispatchEvent(pointer("pointermove", 14)));
  expect(order(container)[0]).toBe("sources");
  await act(async () => dom.window.dispatchEvent(pointer("pointerup", 14)));
  expect(JSON.parse(dom.window.localStorage.getItem(ORDER_KEY)!)[0]).toBe("sources");
  await act(async () => root.unmount());
});

test("an arrow key during a pointer drag changes nothing, so Escape still restores the order", async () => {
  const { container, root } = await mount();
  stack(container, HEIGHTS);
  await act(async () => handle(container, "tasks").dispatchEvent(pointer("pointerdown", 580)));
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

test("Up and Down Arrow on a handle move the section one place, across a block's edge, keeping focus", async () => {
  const { container, root } = await mount();
  const key = (id: string, name: string) =>
    act(async () => {
      handle(container, id).dispatchEvent(new dom.window.KeyboardEvent("keydown", { key: name, bubbles: true }));
    });
  handle(container, "subagents").focus();
  await key("subagents", "ArrowUp");
  expect(order(container).slice(4, 7)).toEqual(["sources", "subagents", "outputs"]);
  expect(dom.window.document.activeElement).toBe(handle(container, "subagents"));
  await key("subagents", "ArrowDown");
  expect(layout(container)).toEqual(DEFAULT);
  // Already first or last: it stays.
  await key("environment", "ArrowUp");
  await key("tasks", "ArrowDown");
  expect(layout(container)).toEqual(DEFAULT);
  await act(async () => root.unmount());
});

test("the per-block order #27291 saved is read as one order, nothing lost", async () => {
  dom.window.localStorage.setItem(
    ORDER_KEY,
    JSON.stringify({ about: ["context", "environment", "connectors"], made: ["outputs", "changes"] }),
  );
  const { container, root } = await mount();
  expect(layout(container)).toEqual([
    { group: "about", sections: ["context", "environment", "connectors"] },
    // Sources, missing, takes its place after Changes, the section it follows by default.
    { group: "made", sections: ["outputs", "changes", "sources"] },
    { group: "running", sections: ["subagents", "tasks"] },
  ]);
  // Unchanged storage until the person moves something; then the one order.
  expect(JSON.parse(dom.window.localStorage.getItem(ORDER_KEY)!)).toHaveProperty("about");
  await act(async () => {
    handle(container, "tasks").dispatchEvent(
      new dom.window.KeyboardEvent("keydown", { key: "ArrowUp", bubbles: true }),
    );
  });
  expect(JSON.parse(dom.window.localStorage.getItem(ORDER_KEY)!)).toEqual([
    "context",
    "environment",
    "connectors",
    "outputs",
    "changes",
    "sources",
    "tasks",
    "subagents",
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
    "connectors",
    "changes",
    "sources",
    "outputs",
    "tasks",
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
  // A section the saved order lacks takes the place after the one it follows by default: Subagents
  // after Outputs, Context after Environment.
  expect(order(container)).toEqual([
    "outputs",
    "subagents",
    "tasks",
    "environment",
    "context",
    "connectors",
    "changes",
    "sources",
  ]);
  await act(async () => root.unmount());
});

test("a panel closed while another pane reorders shows that order when it opens again", async () => {
  const first = await mount();
  await act(async () => first.root.unmount());
  // Another pane's drag, while no panel here listens.
  const moved = ["tasks", "environment", "context", "connectors", "changes", "sources", "outputs", "subagents"];
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
    expect(order(first.container).slice(-2)).toEqual(["tasks", "subagents"]);
    await act(async () => first.root.unmount());
    const again = await mount();
    expect(order(again.container).slice(-2)).toEqual(["tasks", "subagents"]);
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
  expect(JSON.parse(dom.window.localStorage.getItem(ORDER_KEY)!)).toEqual([
    "environment",
    "context",
    "connectors",
    "changes",
    "sources",
    "subagents",
    "outputs",
    "tasks",
  ]);
  await act(async () => root.unmount());
});
