// A popover trigger carries its own state (popoverTrigger.ts): `aria-expanded`, `aria-haspopup` and,
// while open, `aria-controls` naming the popup, so VoiceOver says "collapsed" or "expanded" and can
// move to the popover, whichever caller drew the button.
import { afterEach, expect, test } from "bun:test";
import { act, useState } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import { Popover } from "./Popover";
import { usePopoverTrigger } from "./popoverTrigger";
import { settleReact } from "../../test/support/domTeardown";

let dom: JSDOM | undefined;
let root: Root | undefined;
const scope = globalThis as Record<string, unknown>;
const saved = new Map<string, unknown>();
const KEYS = [
  "window",
  "document",
  "navigator",
  "Node",
  "HTMLElement",
  "Element",
  "MouseEvent",
  "KeyboardEvent",
  "FocusEvent",
  "getComputedStyle",
  "requestAnimationFrame",
  "cancelAnimationFrame",
  "IS_REACT_ACT_ENVIRONMENT",
];

function render(node: React.ReactNode): Document {
  dom = new JSDOM("<!doctype html><html><body><main id=root></main></body></html>", {
    url: "http://localhost/",
    pretendToBeVisual: true,
  });
  for (const key of KEYS) saved.set(key, scope[key]);
  const win = dom.window;
  Object.assign(scope, {
    window: win,
    document: win.document,
    navigator: win.navigator,
    Node: win.Node,
    HTMLElement: win.HTMLElement,
    Element: win.Element,
    MouseEvent: win.MouseEvent,
    KeyboardEvent: win.KeyboardEvent,
    FocusEvent: win.FocusEvent,
    getComputedStyle: win.getComputedStyle.bind(win),
    requestAnimationFrame: (callback: FrameRequestCallback) => setTimeout(() => callback(Date.now()), 0),
    cancelAnimationFrame: (handle: number) => clearTimeout(handle),
    IS_REACT_ACT_ENVIRONMENT: true,
  });
  root = createRoot(win.document.getElementById("root")!);
  act(() => root!.render(node));
  return win.document;
}

afterEach(async () => {
  if (root)
    await act(async () => {
      root!.unmount();
      await new Promise((resolve) => setTimeout(resolve, 0));
    });
  root = undefined;
  await settleReact();
  for (const [key, value] of saved) {
    if (value === undefined) delete scope[key];
    else scope[key] = value;
  }
  saved.clear();
  dom?.window.close();
  dom = undefined;
});

const settle = () =>
  act(async () => {
    await new Promise((resolve) => setTimeout(resolve, 0));
  });

/** A keyboard activation: a click with no pointer press before it (`detail` 0). */
const keyboardClick = (element: Element) =>
  act(() => {
    element.dispatchEvent(new dom!.window.MouseEvent("click", { bubbles: true, cancelable: true, detail: 0 }));
  });

function Chip() {
  const [open, setOpen] = useState(false);
  // The anchor element in state, not a ref: render reads no ref (React Compiler).
  const [button, setButton] = useState<HTMLButtonElement | null>(null);
  const trigger = usePopoverTrigger(open, setOpen);
  return (
    <>
      <button ref={setButton} type="button" {...trigger}>
        Branch
      </button>
      <Popover
        id={trigger["aria-controls"]}
        open={open}
        onOpenChange={setOpen}
        anchor={open ? button : null}
        label="Branch status"
      >
        <p>clean</p>
      </Popover>
    </>
  );
}

test("a closed popover trigger says it opens a dialog and is collapsed", () => {
  const doc = render(<Chip />);
  const button = doc.querySelector("button")!;
  expect(button.getAttribute("aria-haspopup")).toBe("dialog");
  expect(button.getAttribute("aria-expanded")).toBe("false");
  expect(button.hasAttribute("aria-controls")).toBe(false);
});

test("an open popover trigger is expanded and controls the popover it opened", async () => {
  const doc = render(<Chip />);
  const button = doc.querySelector("button")!;
  keyboardClick(button);
  await settle();
  expect(button.getAttribute("aria-expanded")).toBe("true");
  const dialog = doc.querySelector<HTMLElement>('[role="dialog"]');
  expect(dialog?.getAttribute("aria-label")).toBe("Branch status");
  expect(button.getAttribute("aria-controls")).toBe(dialog!.id);
  // A second activation closes it, and the trigger says so again.
  keyboardClick(button);
  await settle();
  expect(button.getAttribute("aria-expanded")).toBe("false");
  expect(button.hasAttribute("aria-controls")).toBe(false);
});

test("a trigger for a caller-drawn popup names its role and id", () => {
  function List() {
    const [open, setOpen] = useState(true);
    const trigger = usePopoverTrigger(open, setOpen, undefined, { popup: "listbox", popupId: "models" });
    return (
      <>
        <button type="button" {...trigger}>
          Model
        </button>
        {/* oxlint-disable-next-line jsx-a11y/prefer-tag-over-role -- stands in for a caller's drawn list. */}
        {open && <div id="models" role="listbox" aria-label="Models" />}
      </>
    );
  }
  const doc = render(<List />);
  const button = doc.querySelector("button")!;
  expect(button.getAttribute("aria-haspopup")).toBe("listbox");
  expect(button.getAttribute("aria-expanded")).toBe("true");
  expect(button.getAttribute("aria-controls")).toBe("models");
});

test("two triggers on one page control different popovers", async () => {
  const doc = render(
    <>
      <Chip />
      <Chip />
    </>,
  );
  const [first, second] = [...doc.querySelectorAll("button")];
  keyboardClick(first!);
  await settle();
  const a = first!.getAttribute("aria-controls");
  keyboardClick(first!);
  keyboardClick(second!);
  await settle();
  const b = second!.getAttribute("aria-controls");
  expect(doc.getElementById(b!)?.getAttribute("role")).toBe("dialog");
  expect(a).toBeTruthy();
  expect(b).toBeTruthy();
  expect(a).not.toBe(b);
});
