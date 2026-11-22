import { afterAll, afterEach, expect, test } from "bun:test";
import { JSDOM, VirtualConsole } from "jsdom";
import { ContextMenu } from "./ContextMenu";

const dom = new JSDOM("<!doctype html><div id=root></div>", {
  pretendToBeVisual: true,
  virtualConsole: new VirtualConsole(),
});
const globals = globalThis as Record<string, unknown>;
const saved = Object.fromEntries(
  ["window", "document", "navigator", "Element", "HTMLElement", "Node", "IS_REACT_ACT_ENVIRONMENT"].map((key) => [
    key,
    globals[key],
  ]),
);
Object.assign(globals, {
  window: dom.window,
  document: dom.window.document,
  navigator: dom.window.navigator,
  Element: dom.window.Element,
  HTMLElement: dom.window.HTMLElement,
  Node: dom.window.Node,
  IS_REACT_ACT_ENVIRONMENT: true,
});
afterAll(() => Object.assign(globals, saved));

const { act } = await import("react");
const { createRoot } = await import("react-dom/client");

const doc = dom.window.document;
let root: ReturnType<typeof createRoot>;

afterEach(async () => act(async () => root.unmount()));

test("Escape closes a context menu and restores focus to its invoking control", async () => {
  root = createRoot(doc.getElementById("root")!);
  await act(async () =>
    root.render(
      <ContextMenu items={[{ id: "copy", label: "Copy", onSelect: () => undefined }]}>
        <button type="button" id="target">
          Target
        </button>
      </ContextMenu>,
    ),
  );

  const target = doc.getElementById("target") as HTMLButtonElement;
  target.focus();
  await act(async () =>
    target.dispatchEvent(
      new dom.window.MouseEvent("contextmenu", { bubbles: true, cancelable: true, clientX: 24, clientY: 18 }),
    ),
  );

  const menu = doc.querySelector<HTMLElement>('[role="menu"]');
  expect(menu).not.toBeNull();
  expect(doc.activeElement).toBe(menu);

  await act(async () =>
    menu!.dispatchEvent(new dom.window.KeyboardEvent("keydown", { key: "Escape", bubbles: true, cancelable: true })),
  );
  expect(doc.querySelector('[role="menu"]')).toBeNull();
  expect(doc.activeElement).toBe(target);
});
