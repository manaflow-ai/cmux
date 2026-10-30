// l10n-allow-file: test fixture names, not shipped UI.
// Session Info's sections move by drag and stay where they were put (Leo, 2026-10-29: "LITERALLY BE
// THE EXACT SAME FUCKING SITUTAION AS BEFORE BUT NOW YOU CAN FUCKING FCLICK AND DRAG TO REARRANGE").
// - Its default layout does not change by accident: the three blocks and their sections, in order,
//   are pinned here (the gallery's full chat, every section shown). A change to them changes this test.
// - Dragging a section's six-dot handle past a neighbour's middle moves it there (the drag follows the
//   pointer on the window, so moving the section never drops it); Up and Down Arrow on
//   the handle move it one place; a section moves only inside its own block.
// - The order is kept (localStorage) and read again by a fresh panel; another pane's drag reaches
//   this one through the `storage` event.
// inspector-section-order-browser.test.tsx checks in Chromium that the handles draw nothing until hover.
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
const { ChatInspector } = await import("../src/agent-session/acpmux/inspector/ChatInspector");
const { resetInspectorState } = await import("../src/agent-session/acpmux/inspector/inspectorState");
const { ORDER_KEY, resetSectionOrderForTests } = await import("../src/agent-session/acpmux/inspector/sectionOrder");
const gallery = (await import("../src/agent-session/acpmux/inspector/ChatInspector.gallery")).default;
type InspectorProps = import("react").ComponentProps<typeof ChatInspector>;

afterAll(() => {
  setPaneLanguage("en");
  dom.window.close();
  for (const [key, had, value] of saved) {
    if (had) scope[key] = value;
    else delete scope[key];
  }
});
setPaneLanguage("en");

const full = gallery.variants.full!.props as InspectorProps;

beforeEach(() => {
  dom.window.localStorage.clear();
  resetSectionOrderForTests();
  resetInspectorState();
});

async function mount(props: InspectorProps = full) {
  const container = dom.window.document.createElement("main");
  dom.window.document.body.replaceChildren(container);
  const root = createRoot(container);
  await act(async () => root.render(createElement(ChatInspector, props)));
  return { container, root };
}

/// Each block and its sections, in the order drawn.
const layout = (container: HTMLElement) =>
  [...container.querySelectorAll<HTMLElement>(".acpmux-chat-inspector__body > *")].map((child) => ({
    group: child.dataset.group ?? child.className,
    sections: [...child.querySelectorAll<HTMLElement>(":scope > section[data-section]")].map(
      (section) => section.dataset.section,
    ),
  }));

const handle = (container: HTMLElement, id: string) =>
  container.querySelector<HTMLButtonElement>(`section[data-section="${id}"] > .acpmux-chat-inspector-section__handle`)!;

/// Lays a block's sections out top to bottom at the given heights (jsdom has no layout).
function stack(container: HTMLElement, heights: Record<string, number>) {
  let top = 0;
  for (const [id, height] of Object.entries(heights)) {
    const section = container.querySelector<HTMLElement>(`section[data-section="${id}"]`)!;
    const at = top;
    section.getBoundingClientRect = () => ({ top: at, height, bottom: at + height }) as DOMRect;
    top += height;
  }
}

const pointer = (type: string, clientY: number) =>
  new dom.window.MouseEvent(type, { bubbles: true, cancelable: true, button: 0, clientY });

test("the default layout: three blocks and their sections, in order", async () => {
  const { container, root } = await mount();
  expect(layout(container)).toEqual([
    { group: "about", sections: ["environment", "context", "connectors"] },
    { group: "made", sections: ["changes", "sources", "outputs"] },
    { group: "running", sections: ["subagents", "tasks"] },
  ]);
  // A handle is the only thing each section gained, first in it, and it takes no text.
  for (const section of container.querySelectorAll<HTMLElement>("section[data-section]")) {
    const first = section.firstElementChild as HTMLElement;
    expect(first.className).toBe("acpmux-chat-inspector-section__handle");
    expect(first.textContent).toBe("");
    expect(first.getAttribute("aria-label")).toBe(
      translate("chatInspector.reorderSection", { section: section.getAttribute("aria-label")! }),
    );
  }
  expect(dom.window.localStorage.getItem(ORDER_KEY)).toBeNull();
  await act(async () => root.unmount());
});

test("dragging a handle past a neighbour's middle moves the section there, and the order stays", async () => {
  const { container, root } = await mount();
  stack(container, { environment: 100, context: 28, connectors: 28 });
  const grip = handle(container, "environment");
  await act(async () => grip.dispatchEvent(pointer("pointerdown", 10)));
  expect(container.querySelector('section[data-section="environment"]')!.hasAttribute("data-dragging")).toBe(true);
  // Past Context's middle (114) only.
  await act(async () => dom.window.dispatchEvent(pointer("pointermove", 120)));
  expect(layout(container)[0]!.sections).toEqual(["context", "environment", "connectors"]);
  // Past Connectors' middle too.
  stack(container, { context: 28, environment: 100, connectors: 28 });
  await act(async () => dom.window.dispatchEvent(pointer("pointermove", 150)));
  expect(layout(container)[0]!.sections).toEqual(["context", "connectors", "environment"]);
  await act(async () => dom.window.dispatchEvent(pointer("pointerup", 150)));
  expect(container.querySelector("[data-dragging]")).toBeNull();
  // The other blocks never moved.
  expect(layout(container).slice(1)).toEqual([
    { group: "made", sections: ["changes", "sources", "outputs"] },
    { group: "running", sections: ["subagents", "tasks"] },
  ]);
  await act(async () => root.unmount());

  // A fresh page reads the saved order.
  resetSectionOrderForTests();
  const again = await mount();
  expect(layout(again.container)[0]!.sections).toEqual(["context", "connectors", "environment"]);
  await act(async () => again.root.unmount());
});

test("Up and Down Arrow on a handle move the section one place, inside its block", async () => {
  const { container, root } = await mount();
  const key = (id: string, name: string) =>
    act(async () => {
      handle(container, id).dispatchEvent(new dom.window.KeyboardEvent("keydown", { key: name, bubbles: true }));
    });
  await key("tasks", "ArrowUp");
  expect(layout(container)[2]!.sections).toEqual(["tasks", "subagents"]);
  // Already first: it stays.
  await key("tasks", "ArrowUp");
  expect(layout(container)[2]!.sections).toEqual(["tasks", "subagents"]);
  await key("tasks", "ArrowDown");
  expect(layout(container)[2]!.sections).toEqual(["subagents", "tasks"]);
  await act(async () => root.unmount());
});

test("another pane's drag reaches this one", async () => {
  const { container, root } = await mount();
  const value = JSON.stringify({ made: ["outputs", "changes"] });
  dom.window.localStorage.setItem(ORDER_KEY, value);
  await act(async () => {
    dom.window.dispatchEvent(new dom.window.StorageEvent("storage", { key: ORDER_KEY, newValue: value }));
  });
  expect(layout(container)[1]!.sections).toEqual(["outputs", "changes", "sources"]);
  await act(async () => root.unmount());
});

test("a panel closed while another pane reorders shows that order when it opens again", async () => {
  const first = await mount();
  await act(async () => first.root.unmount());
  // Another pane's drag, while no panel here listens.
  dom.window.localStorage.setItem(ORDER_KEY, JSON.stringify({ running: ["tasks", "subagents"] }));
  const again = await mount();
  expect(layout(again.container)[2]!.sections).toEqual(["tasks", "subagents"]);
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
    expect(layout(first.container)[2]!.sections).toEqual(["tasks", "subagents"]);
    await act(async () => first.root.unmount());
    const again = await mount();
    expect(layout(again.container)[2]!.sections).toEqual(["tasks", "subagents"]);
    await act(async () => again.root.unmount());
  } finally {
    dom.window.Storage.prototype.setItem = setItem;
  }
});

test("a saved order with unknown or missing sections keeps every section once", async () => {
  dom.window.localStorage.setItem(
    ORDER_KEY,
    JSON.stringify({ about: ["context", "bogus", "context", "environment"], made: 3 }),
  );
  const { container, root } = await mount();
  expect(layout(container).map((block) => block.sections)).toEqual([
    // Connectors, missing, takes its place after Context, the section it follows by default.
    ["context", "connectors", "environment"],
    ["changes", "sources", "outputs"],
    ["subagents", "tasks"],
  ]);
  await act(async () => root.unmount());
});

test("Sources remains visible and keeps its reordered position after reopening", async () => {
  const first = await mount();
  await act(async () => {
    handle(first.container, "sources").dispatchEvent(
      new dom.window.KeyboardEvent("keydown", { key: "ArrowUp", bubbles: true }),
    );
  });
  expect(layout(first.container)[1]!.sections).toEqual(["sources", "changes", "outputs"]);
  await act(async () => first.root.unmount());
  resetSectionOrderForTests();
  const again = await mount();
  expect(layout(again.container)[1]!.sections).toEqual(["sources", "changes", "outputs"]);
  await act(async () => again.root.unmount());
});
