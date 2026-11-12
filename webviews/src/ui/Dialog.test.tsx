// The shared dialog (Dialog.tsx): a visible DialogTitle names it and a DialogDescription describes it,
// the way VoiceOver reads a native sheet; `alert` makes a confirm an alertdialog that a press outside
// never dismisses, while Escape still does.
import { afterEach, expect, test } from "bun:test";
import { act, useState } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import { Dialog, DialogDescription, DialogTitle } from "./Dialog";
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
  "PointerEvent",
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
    PointerEvent: win.MouseEvent,
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

const text = (doc: Document, ids: string | null) =>
  (ids ?? "")
    .split(/\s+/)
    .filter(Boolean)
    .map((id) => doc.getElementById(id)?.textContent ?? "")
    .join(" ");

/** Opens with the dialog shown, and counts every close it asks for. */
function Confirm({ alert, closes }: { alert?: boolean; closes: string[] }) {
  const [open, setOpen] = useState(true);
  return (
    <>
      <button type="button" id="outside">
        Behind
      </button>
      <Dialog
        open={open}
        alert={alert}
        onOpenChange={(next) => {
          if (!next) closes.push("close");
          setOpen(next);
        }}
      >
        <DialogTitle>Delete this chat?</DialogTitle>
        <DialogDescription>Its messages and files go too. This cannot be undone.</DialogDescription>
        <button type="button">Cancel</button>
      </Dialog>
    </>
  );
}

test("a dialog's visible title names it and its sentence describes it", async () => {
  const doc = render(<Confirm closes={[]} />);
  await settle();
  const dialog = doc.querySelector<HTMLElement>('[role="dialog"]')!;
  expect(dialog).toBeTruthy();
  expect(dialog.hasAttribute("aria-label")).toBe(false);
  expect(text(doc, dialog.getAttribute("aria-labelledby"))).toBe("Delete this chat?");
  expect(text(doc, dialog.getAttribute("aria-describedby"))).toBe(
    "Its messages and files go too. This cannot be undone.",
  );
  expect(doc.querySelector("h2")?.textContent).toBe("Delete this chat?");
});

test("a dialog with no title is still named by its label", async () => {
  const doc = render(
    <Dialog open onOpenChange={() => {}} label="Settings">
      <button type="button">Done</button>
    </Dialog>,
  );
  await settle();
  expect(doc.querySelector('[role="dialog"]')?.getAttribute("aria-label")).toBe("Settings");
});

test("an alert dialog is role alertdialog, named and described by its title and sentence", async () => {
  const doc = render(<Confirm alert closes={[]} />);
  await settle();
  expect(doc.querySelector('[role="dialog"]')).toBeNull();
  const dialog = doc.querySelector<HTMLElement>('[role="alertdialog"]')!;
  expect(dialog).toBeTruthy();
  expect(text(doc, dialog.getAttribute("aria-labelledby"))).toBe("Delete this chat?");
  expect(text(doc, dialog.getAttribute("aria-describedby"))).toContain("cannot be undone");
});

const pressOutside = (doc: Document) =>
  act(async () => {
    const target = doc.querySelector(".ui-backdrop") ?? doc.getElementById("outside")!;
    for (const type of ["pointerdown", "mousedown", "pointerup", "mouseup", "click"])
      target.dispatchEvent(new dom!.window.MouseEvent(type, { bubbles: true, cancelable: true, button: 0 }));
    await new Promise((resolve) => setTimeout(resolve, 0));
  });

const escape = (doc: Document) =>
  act(async () => {
    (doc.activeElement ?? doc.body).dispatchEvent(
      new dom!.window.KeyboardEvent("keydown", { key: "Escape", bubbles: true, cancelable: true }),
    );
    await new Promise((resolve) => setTimeout(resolve, 0));
  });

test("a press outside dismisses a dialog but never an alert dialog", async () => {
  const plain: string[] = [];
  let doc = render(<Confirm closes={plain} />);
  await settle();
  await pressOutside(doc);
  expect(plain).toEqual(["close"]);
  await act(async () => root!.unmount());
  root = undefined;

  const alerted: string[] = [];
  root = createRoot(dom!.window.document.getElementById("root")!);
  act(() => root!.render(<Confirm alert closes={alerted} />));
  doc = dom!.window.document;
  await settle();
  await pressOutside(doc);
  expect(alerted).toEqual([]);
  expect(doc.querySelector('[role="alertdialog"]')).toBeTruthy();
});

test("Escape still closes an alert dialog", async () => {
  const closes: string[] = [];
  const doc = render(<Confirm alert closes={closes} />);
  await settle();
  await escape(doc);
  expect(closes).toEqual(["close"]);
});
