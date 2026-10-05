import { afterAll, afterEach, beforeEach, expect, test } from "bun:test";
import { JSDOM, VirtualConsole } from "jsdom";
import type { AcpmuxSnapshot } from "./model";

const dom = new JSDOM("<!doctype html><div id=root></div>", {
  pretendToBeVisual: true,
  virtualConsole: new VirtualConsole(),
});
const globals = globalThis as Record<string, unknown>;
const saved = Object.fromEntries(
  [
    "window",
    "document",
    "navigator",
    "HTMLElement",
    "Node",
    "requestAnimationFrame",
    "cancelAnimationFrame",
    "IS_REACT_ACT_ENVIRONMENT",
  ].map((key) => [key, globals[key]]),
);
Object.assign(globals, {
  window: dom.window,
  document: dom.window.document,
  navigator: dom.window.navigator,
  HTMLElement: dom.window.HTMLElement,
  Node: dom.window.Node,
  requestAnimationFrame: (callback: FrameRequestCallback) => setTimeout(() => callback(0), 0) as unknown as number,
  cancelAnimationFrame: (handle: number) => clearTimeout(handle),
  IS_REACT_ACT_ENVIRONMENT: true,
});
// The pickers are shared Base UI components (src/ui), which reach for DOM classes by name.
const domClasses = Object.getOwnPropertyNames(dom.window).filter(
  (key) =>
    /^(HTML|SVG|Element|Event|KeyboardEvent|PointerEvent|MouseEvent|FocusEvent|Shadow|Document|Mutation|Resize|getComputedStyle)/.test(
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
const { ComposerContext } = await import("./ComposerContext");

const sessions: AcpmuxSnapshot["sessions"] = [
  { sessionId: "local", cwd: "/Users/me/code/cmux", host: "This Mac", hostKind: "local" },
  { sessionId: "cloud", cwd: "/workspace/cmux", host: "devbox", hostKind: "cloud" },
];
type Summary = NonNullable<AcpmuxSnapshot["summary"]>;
const doc = dom.window.document;
let root: ReturnType<typeof createRoot>;
let picked: Array<[string, string | undefined]>;

beforeEach(() => {
  root = createRoot(doc.getElementById("root")!);
  picked = [];
});
afterEach(async () => act(async () => root.unmount()));

const render = (summary: Partial<Summary> = {}, started = false) =>
  act(async () =>
    root.render(
      createElement(ComposerContext, {
        summary: {
          sessionId: "s",
          cwd: "/Users/me/code/cmux",
          host: "This Mac",
          hostKind: "local",
          ...summary,
        },
        sessions,
        started,
        onProject: (cwd: string, peer?: string) => picked.push([cwd, peer]),
      }),
    ),
  );

test("renders plain right-aligned computer and folder pickers without context chips", async () => {
  await render();
  expect(doc.querySelectorAll(".acpmux-context-chip")).toHaveLength(0);
  expect([...doc.querySelectorAll(".acpmux-location-button")].map((button) => button.textContent)).toEqual([
    "This Mac⌄",
    "cmux⌄",
  ]);
});

test("offers Cloud computers and sends the selected computer with its folder", async () => {
  await render();
  const computer = doc.querySelector<HTMLButtonElement>('[aria-label="Computer"]')!;
  await act(async () => computer.click());
  expect(
    // The computer menu is a shared radio menu (src/ui Menu): its items are menuitemradio rows.
    [...doc.querySelectorAll('.acpmux-location-menu [role="menuitemradio"]')].map((row) =>
      row.textContent?.replace("✓", ""),
    ),
  ).toEqual(["This Mac", "devboxCloud"]);
  await act(async () => doc.querySelectorAll<HTMLElement>('.acpmux-location-menu [role="menuitemradio"]')[1]!.click());
  const folder = doc.querySelector<HTMLButtonElement>('[aria-label="Folder"]')!;
  expect(folder.textContent).toContain("cmux");
  await act(async () => folder.click());
  expect(picked).toEqual([["/workspace/cmux", "devbox"]]);
});

test("locks both location labels after the first turn", async () => {
  await render({ turnCount: 1 }, true);
  expect(doc.querySelectorAll(".acpmux-location-button")).toHaveLength(0);
  expect(doc.querySelectorAll(".acpmux-location-readonly")).toHaveLength(2);
  expect(doc.querySelector(".acpmux-composer-context")?.getAttribute("data-readonly")).toBe("true");
});

test("the folder picker takes a typed absolute path on Return", async () => {
  await render();
  await act(async () => doc.querySelector<HTMLButtonElement>('[aria-label="Folder"]')!.click());
  const field = doc.querySelector<HTMLInputElement>(".acpmux-location-search")!;
  expect(field).not.toBeNull();
  await act(async () => {
    const setter = Object.getOwnPropertyDescriptor(dom.window.HTMLInputElement.prototype, "value")!.set!;
    setter.call(field, "/tmp/scratch");
    field.dispatchEvent(new dom.window.Event("input", { bubbles: true }));
  });
  await act(async () => {
    field.dispatchEvent(new dom.window.KeyboardEvent("keydown", { key: "Enter", bubbles: true, cancelable: true }));
  });
  expect(picked.at(-1)?.[0]).toBe("/tmp/scratch");
});

test("folder rows show the project name over its path, and typing filters on both", async () => {
  await render();
  await act(async () => doc.querySelector<HTMLButtonElement>('[aria-label="Folder"]')!.click());
  const rows = () =>
    [...doc.querySelectorAll('.acpmux-location-menu [role="option"]')].map((row) => [
      row.querySelector(".acpmux-menu-label")?.textContent,
      row.querySelector(".acpmux-menu-description")?.textContent,
    ]);
  expect(rows()).toEqual([["cmux", "/Users/me/code/cmux"]]);
  const field = doc.querySelector<HTMLInputElement>(".acpmux-location-search")!;
  const type = (text: string) =>
    act(async () => {
      Object.getOwnPropertyDescriptor(dom.window.HTMLInputElement.prototype, "value")!.set!.call(field, text);
      field.dispatchEvent(new dom.window.Event("input", { bubbles: true }));
    });
  await type("code");
  expect(rows()).toEqual([["cmux", "/Users/me/code/cmux"]]);
  await type("nothing-matches");
  expect(rows()).toEqual([]);
});
