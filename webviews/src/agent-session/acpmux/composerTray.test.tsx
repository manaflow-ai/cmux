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
