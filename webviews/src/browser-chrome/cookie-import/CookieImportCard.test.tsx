// Leo, 2026-11-07, of the Import Cookies banner: "this looks kind of ugly, to be honest. Like this
// isn't styled well." The card's answers are one aligned row: Not Now and Import the same
// compact buttons (subtle and the accent), Don't Show Again a quiet ghost button of the same
// height; every answer reaches the host; the page draws only the host's lines and an inline icon.
import { afterEach, expect, test } from "bun:test";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import { CookieImportCard } from "./CookieImportCard";
import { cookieImportModel, type CookieImportCardModel, type CookieImportCommand } from "./model";

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
  "PointerEvent",
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
    PointerEvent: win.MouseEvent,
    getComputedStyle: win.getComputedStyle,
    // The Keep in sync checkbox (Base UI) schedules its state on a frame.
    requestAnimationFrame: win.requestAnimationFrame.bind(win),
    cancelAnimationFrame: win.cancelAnimationFrame.bind(win),
    IS_REACT_ACT_ENVIRONMENT: true,
  });
  root = createRoot(win.document.getElementById("root")!);
  act(() => root!.render(node));
  return win.document;
}

afterEach(() => {
  act(() => root?.unmount());
  root = undefined;
  for (const [key, value] of saved) scope[key] = value;
  saved.clear();
  dom?.window.close();
  dom = undefined;
});

const model: CookieImportCardModel = {
  title: "Import cookies from Google Chrome",
  detail: "Stay signed in to your sites. Nothing leaves this Mac.",
  importTitle: "Import…",
  notNowTitle: "Not Now",
  neverTitle: "Don't Show Again",
  icon: "data:image/png;base64,AAAA",
  keepInSyncTitle: "Keep in sync",
  keepInSync: true,
};

test("the answers are one row: the link first, then Not Now and Import as matched compact buttons", () => {
  const doc = render(<CookieImportCard model={model} onChoice={() => undefined} glass={false} />);
  const row = doc.querySelector(".ci-row")!;
  const buttons = [...row.querySelectorAll("button")];
  expect(doc.querySelectorAll(".ci-row .ci-keep").length).toBe(0);
  expect(buttons.map((b) => b.textContent)).toEqual(["Don't Show Again", "Not Now", "Import…"]);
  expect(buttons.map((b) => b.getAttribute("data-size"))).toEqual(["sm", "sm", "sm"]);
  expect(buttons.map((b) => b.getAttribute("data-variant"))).toEqual(["ghost", "subtle", "solid"]);
  // Not Now and Import share one grid, so they take one width.
  expect(buttons[1]!.parentElement).toBe(buttons[2]!.parentElement);
  expect(buttons[1]!.parentElement!.className).toBe("ci-answers");
});

test("every answer reaches the host; Import carries Keep in sync, on by default", () => {
  const answers: CookieImportCommand[] = [];
  const doc = render(<CookieImportCard model={model} onChoice={(choice) => answers.push(choice)} glass={false} />);
  for (const button of doc.querySelectorAll<HTMLElement>(".ci-row button")) act(() => button.click());
  expect(answers).toEqual([{ type: "never" }, { type: "notNow" }, { type: "import", keepInSync: true }]);
});

// Leo, 2026-11-07: "we should be able to, like, just keep it in sync always, right?" The card offers
// it at import time, checked; unchecking it imports once.
test("Keep in sync is a checkbox under the detail, checked; unchecked, Import says so", () => {
  const answers: CookieImportCommand[] = [];
  const doc = render(<CookieImportCard model={model} onChoice={(choice) => answers.push(choice)} glass={false} />);
  const keep = doc.querySelector(".ci-text .ci-keep")!;
  expect(keep.textContent).toBe("Keep in sync");
  const box = keep.querySelector('[role="checkbox"]')!;
  expect(box.getAttribute("aria-checked")).toBe("true");
  act(() => (box as HTMLElement).click());
  expect(box.getAttribute("aria-checked")).toBe("false");
  act(() => (doc.querySelector(".ci-row [data-variant=solid]") as HTMLElement).click());
  expect(answers).toEqual([{ type: "import", keepInSync: false }]);
});

test("no Keep in sync title: no checkbox, and Import carries no choice", () => {
  const answers: CookieImportCommand[] = [];
  const doc = render(
    <CookieImportCard model={{ ...model, keepInSyncTitle: null }} onChoice={(choice) => answers.push(choice)} />,
  );
  expect(doc.querySelector(".ci-keep")).toBeNull();
  act(() => (doc.querySelector(".ci-row [data-variant=solid]") as HTMLElement).click());
  expect(answers).toEqual([{ type: "import" }]);
});

test("no Don't Show Again: only the two buttons", () => {
  const doc = render(<CookieImportCard model={{ ...model, neverTitle: null }} onChoice={() => undefined} />);
  expect([...doc.querySelectorAll(".ci-row button")].map((b) => b.textContent)).toEqual(["Not Now", "Import…"]);
});

test("the pushed state needs its lines; the icon is only an inline image", () => {
  expect(cookieImportModel({ title: "T" })).toBeNull();
  expect(cookieImportModel(null)).toBeNull();
  const read = cookieImportModel({ ...model, icon: "https://example.com/icon.png", neverTitle: "" });
  expect(read?.icon).toBeNull();
  expect(read?.neverTitle).toBeNull();
  expect(cookieImportModel(model)?.icon).toBe(model.icon);
  expect(cookieImportModel({ ...model, keepInSync: false })?.keepInSync).toBe(false);
  expect(cookieImportModel({ ...model, keepInSync: undefined })?.keepInSync).toBe(true);
});
