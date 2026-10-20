// u2647: every dialog button shows the key that presses it ("Cancel ⎋", "Create ↩", "Don't Save ⌘D"),
// names it to assistive tech, and a Command key really presses it. The Home sheets (FormDialog) use it:
// Escape on Cancel, Return on the primary submit button.
import { afterEach, expect, test } from "bun:test";
import { act, createRef } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import { DialogButton, dialogKeyAria, dialogKeyGlyph } from "./DialogButton";

let dom: JSDOM | undefined;
let root: Root | undefined;
const scope = globalThis as Record<string, unknown>;
const saved = new Map<string, unknown>();

function installDom(): HTMLElement {
  dom = new JSDOM("<!doctype html><html><body><main id=root></main></body></html>", { url: "http://localhost/" });
  for (const key of [
    "window",
    "document",
    "navigator",
    "Node",
    "HTMLElement",
    "Element",
    "KeyboardEvent",
    "IS_REACT_ACT_ENVIRONMENT",
  ])
    saved.set(key, scope[key]);
  Object.assign(scope, {
    window: dom.window,
    document: dom.window.document,
    navigator: dom.window.navigator,
    Node: dom.window.Node,
    HTMLElement: dom.window.HTMLElement,
    Element: dom.window.Element,
    KeyboardEvent: dom.window.KeyboardEvent,
    IS_REACT_ACT_ENVIRONMENT: true,
  });
  return dom.window.document.getElementById("root")!;
}

afterEach(() => {
  act(() => root?.unmount());
  root = undefined;
  dom?.window.close();
  dom = undefined;
  for (const [key, value] of saved) scope[key] = value;
  saved.clear();
});

function render(node: React.ReactNode): HTMLElement {
  const host = installDom();
  root = createRoot(host);
  act(() => root!.render(node));
  return host;
}

function press(key: string, meta: boolean) {
  act(() => {
    document.dispatchEvent(new KeyboardEvent("keydown", { key, metaKey: meta, bubbles: true, cancelable: true }));
  });
}

test("keys read as macOS writes them", () => {
  expect(dialogKeyGlyph("return")).toBe("↩");
  expect(dialogKeyGlyph("escape")).toBe("⎋");
  expect(dialogKeyGlyph({ command: "d" })).toBe("⌘D");
  expect(dialogKeyAria("return")).toBe("Enter");
  expect(dialogKeyAria("escape")).toBe("Escape");
  expect(dialogKeyAria({ command: "d" })).toBe("Meta+D");
});

test("the approval sheet's buttons show Escape and Return after their titles", () => {
  const host = render(
    <footer>
      <DialogButton dialogKey="escape">Cancel</DialogButton>
      <DialogButton dialogKey="return" type="submit">
        Change
      </DialogButton>
    </footer>,
  );
  const [cancel, change] = Array.from(host.querySelectorAll("button"));
  expect(cancel.textContent).toBe("Cancel⎋");
  expect(change.textContent).toBe("Change↩");
  expect(cancel.getAttribute("aria-keyshortcuts")).toBe("Escape");
  expect(change.getAttribute("aria-keyshortcuts")).toBe("Enter");
  expect(change.getAttribute("type")).toBe("submit");
  expect(cancel.getAttribute("type")).toBe("button");
  // The keycap is decoration: the accessible name stays the title, the key comes from aria-keyshortcuts.
  expect(cancel.querySelector("kbd")?.getAttribute("aria-hidden")).toBe("true");
});

test("a Command key presses its button, and not while it is disabled", () => {
  let pressed = 0;
  const host = render(
    <DialogButton dialogKey={{ command: "d" }} onClick={() => pressed++}>
      Don't Save
    </DialogButton>,
  );
  press("d", true);
  expect(pressed).toBe(1);
  press("d", false);
  expect(pressed).toBe(1);
  act(() =>
    root!.render(
      <DialogButton dialogKey={{ command: "d" }} disabled onClick={() => pressed++}>
        Don't Save
      </DialogButton>,
    ),
  );
  press("d", true);
  expect(pressed).toBe(1);
  expect(host.querySelector("button")?.textContent).toBe("Don't Save⌘D");
});

test("a button no key presses shows no keycap, and the caller's ref still reaches it", () => {
  const ref = createRef<HTMLButtonElement>();
  const host = render(
    <DialogButton dialogKey={null} ref={ref}>
      Choose This Folder
    </DialogButton>,
  );
  const button = host.querySelector("button")!;
  expect(button.querySelector("kbd")).toBeNull();
  expect(button.hasAttribute("aria-keyshortcuts")).toBe(false);
  expect(ref.current).toBe(button);
});
