import { afterAll, afterEach, beforeEach, expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import { JSDOM, VirtualConsole } from "jsdom";
import type { AcpmuxSnapshot } from "./model";

// The composer card and its location row (cx-lzld, Lawrence 2026-10-08: "bottom part looks bad",
// and the folder menu drew under the card). The pane's own stylesheets, in the order the pane
// bundle concatenates them (scripts/cmux-next/build-agent-pane-web.sh), without src/ui/ui.css,
// which the pane does not load.
const css = (path: string) => readFileSync(new URL(path, import.meta.url), "utf8");
const dom = new JSDOM(
  `<!doctype html><style>${[
    "./styles.css",
    "./composerControls.css",
    "./composerStates.css",
    "./composerLocation.css",
    "./composerAttachments.css",
    "./markdownField.css",
    "./header/header.css",
  ]
    .map(css)
    .join("\n")}</style><div id=root></div>`,
  { url: "http://localhost/", pretendToBeVisual: true, virtualConsole: new VirtualConsole() },
);
const globals = globalThis as Record<string, unknown>;
const saved = Object.fromEntries(
  [
    "window",
    "document",
    "navigator",
    "HTMLElement",
    "requestAnimationFrame",
    "cancelAnimationFrame",
    "IS_REACT_ACT_ENVIRONMENT",
  ].map((key) => [key, globals[key]]),
);
const { proseMirrorGlobals } = await import("./promptFieldTesting");
Object.assign(globals, {
  window: dom.window,
  document: dom.window.document,
  navigator: dom.window.navigator,
  HTMLElement: dom.window.HTMLElement,
  ...proseMirrorGlobals(dom.window as unknown as Window & typeof globalThis),
  requestAnimationFrame: (callback: FrameRequestCallback) => setTimeout(() => callback(0), 0) as unknown as number,
  cancelAnimationFrame: (handle: number) => clearTimeout(handle),
  IS_REACT_ACT_ENVIRONMENT: true,
});
const domClasses = Object.getOwnPropertyNames(dom.window).filter(
  (key) =>
    /^(HTML|SVG|Element|Event|KeyboardEvent|PointerEvent|MouseEvent|FocusEvent|Shadow|Document|Mutation|Resize|getComputedStyle|Node)/.test(
      key,
    ) && !(key in globals),
);
for (const key of domClasses) globals[key] = (dom.window as unknown as Record<string, unknown>)[key];
afterAll(() => {
  Object.assign(globals, saved);
  for (const key of domClasses) delete globals[key];
});

const { act, createElement } = await import("react");
const { createRoot } = await import("react-dom/client");
const { Composer } = await import("./Composer");
const { openPicker } = await import("./pickerOpeners");

const doc = dom.window.document;
const snapshot: AcpmuxSnapshot = {
  type: "snapshot",
  protocolVersion: 1,
  rows: [],
  sessions: [],
  connection: "connected",
  isWorking: false,
  queue: [],
  canLoadOlder: false,
  catalog: [],
  summary: { sessionId: "", harness: "claude", model: "opus", cwd: "/Users/me/code/cmux", hostKind: "local" },
};

let root: ReturnType<typeof createRoot>;
beforeEach(() => {
  root = createRoot(doc.getElementById("root")!);
});
afterEach(async () => act(async () => root.unmount()));

const render = async () => {
  await act(async () =>
    root.render(
      createElement(Composer, {
        snapshot,
        chips: () => null,
        localName: "This Mac",
        projectChoices: [
          { cwd: "/Users/me/code/cmux", label: "cmux" },
          { cwd: "/Users/me/code/hq", label: "hq" },
        ],
        onProject: () => undefined,
        onBrowseProject: () => undefined,
        onSend: () => undefined,
        onStop: () => undefined,
      }),
    ),
  );
  await act(() => new Promise((resolve) => setTimeout(resolve, 10)));
};

const zIndex = (element: Element) => {
  const value = Number.parseInt(dom.window.getComputedStyle(element).zIndex, 10);
  return Number.isNaN(value) ? 0 : value;
};

test("the folder and computer row is a footer inside the composer card, not a second card", async () => {
  await render();
  const box = doc.querySelector(".acpmux-composer-box")!;
  const row = doc.querySelector(".acpmux-composer-context")!;
  expect(row).not.toBeNull();
  // One card: the row is inside the card's fill and edge, and paints neither of its own.
  expect(box.contains(row)).toBe(true);
  const style = dom.window.getComputedStyle(row);
  expect(["", "none", "transparent", "rgba(0, 0, 0, 0)"]).toContain(style.backgroundColor || style.background);
  expect(style.marginTop.startsWith("-")).toBe(false);
});

test("an open location menu stacks above the composer card", async () => {
  await render();
  await act(async () => {
    expect(openPicker("Location")).toBe(true);
  });
  await act(() => new Promise((resolve) => setTimeout(resolve, 10)));
  const menu = doc.querySelector(".acpmux-location-menu")!;
  expect(menu).not.toBeNull();
  const positioner = menu.closest(".ui-positioner")!;
  expect(positioner).not.toBeNull();
  // The menu portals out of the composer, and its layer outranks every layer the card makes.
  expect(doc.querySelector(".acpmux-composer")!.contains(positioner)).toBe(false);
  const card = [
    doc.querySelector(".acpmux-composer")!,
    doc.querySelector(".acpmux-composer-box")!,
    doc.querySelector(".acpmux-composer-context")!,
  ];
  expect(zIndex(positioner)).toBeGreaterThan(Math.max(...card.map(zIndex)));
});

// cx-yrgh (nxdog72, Lawrence 2026-10-08): the folder menu still covered the top of the card in the
// app. The row sits at the card's bottom edge, and a menu placed on its control's top side lands
// on the card above the row. jsdom has no layout, so the test gives the card, the row and the
// controls the app's boxes (a 1024x768 pane, the card 190px tall at the bottom) and reads where
// the menu's positioner puts the menu: its bottom must be at or above the card's top edge.
const PANE = { width: 1024, height: 768 };
const CARD = { left: 390, top: 560, right: 1010, bottom: 750 };
const ROW = { left: 390, top: 714, right: 1010, bottom: 750 };
const CONTROL = { left: 417, top: 722, right: 505, bottom: 744 };
const box = (rect: { left: number; top: number; right: number; bottom: number }) => ({
  ...rect,
  x: rect.left,
  y: rect.top,
  width: rect.right - rect.left,
  height: rect.bottom - rect.top,
  toJSON: () => rect,
});
const withAppLayout = async (run: () => Promise<void>) => {
  const proto = dom.window.Element.prototype;
  const original = proto.getBoundingClientRect;
  const html = doc.documentElement;
  proto.getBoundingClientRect = function (this: Element) {
    if (this.matches(".acpmux-composer-box")) return box(CARD) as DOMRect;
    if (this.matches(".acpmux-composer-context")) return box(ROW) as DOMRect;
    if (this.closest(".acpmux-location-picker")) return box(CONTROL) as DOMRect;
    if (this === html || this === doc.body) return box({ left: 0, top: 0, right: PANE.width, bottom: PANE.height }) as DOMRect;
    return box({ left: 0, top: 0, right: 0, bottom: 0 }) as DOMRect;
  };
  for (const [key, value] of [
    ["clientWidth", PANE.width],
    ["clientHeight", PANE.height],
  ] as const)
    Object.defineProperty(html, key, { configurable: true, get: () => value });
  try {
    await run();
  } finally {
    proto.getBoundingClientRect = original;
    delete (html as unknown as Record<string, unknown>).clientWidth;
    delete (html as unknown as Record<string, unknown>).clientHeight;
  }
};
/// The menu's top edge in the pane, once the positioner has placed it (the popup is 0px tall here,
/// so its top is its bottom). Floating UI writes a translate, or top/left, or a bottom offset.
const placedMenuTop = async (positioner: HTMLElement) => {
  const read = () => {
    const style = positioner.style;
    const translate = /translate(?:3d)?\(\s*(-?[\d.]+)px,\s*(-?[\d.]+)px/.exec(style.transform);
    if (translate) return Number(translate[2]) + (Number.parseFloat(style.top) || 0);
    if (style.bottom && style.bottom !== "auto") return PANE.height - Number.parseFloat(style.bottom);
    return Number.parseFloat(style.top) || 0;
  };
  for (let attempt = 0; attempt < 100 && read() === 0; attempt += 1)
    await act(() => new Promise((resolve) => setTimeout(resolve, 10)));
  return read();
};

for (const picker of ["Location", "Computer"]) {
  test(`the ${picker} menu opens fully above the composer card, not over its top`, async () => {
    await withAppLayout(async () => {
      await render();
      await act(async () => {
        expect(openPicker(picker)).toBe(true);
      });
      const menu = doc.querySelector(".acpmux-location-menu")!;
      expect(menu).not.toBeNull();
      const top = await placedMenuTop(menu.closest<HTMLElement>(".ui-positioner")!);
      expect(top).toBeGreaterThan(0);
      expect(top).toBeLessThanOrEqual(CARD.top);
    });
  });
}
