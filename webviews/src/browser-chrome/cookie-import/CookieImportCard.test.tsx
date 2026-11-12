// Leo, 2026-11-08, of the Import Cookies card: "i dont like this. 1. looks bad. 2. not glass. 3. talks
// about too much irrelevant shit". The card is a toast: the browser's icon, one line, Don't Show Again
// (quiet) and Import (bold) as clear text, the close button as Not Now; no detail, no Keep in sync
// (Settings > Browser > Import). Every answer reaches the host; the page draws only the host's words.
import { afterEach, expect, test } from "bun:test";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import { CookieImportCard } from "./CookieImportCard";
import {
  APP_COOKIE_IMPORT_LOOK,
  cookieImportModel,
  type CookieImportCardModel,
  type CookieImportCommand,
} from "./model";

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
  importTitle: "Import…",
  notNowTitle: "Not Now",
  neverTitle: "Don't Show Again",
  icon: "data:image/png;base64,AAAA",
};

// Lawrence 2026-11-09 (msg 26162): the flat gray toast with washed-out text was ugly. The app's look is the
// dialog card's grammar now: the icon, the line in the title's weight, Don't Show Again quiet, Not Now a
// button and Import the filled primary, every answer a labelled button (no bare close glyph).
test("the app's look is the dialog card: icon, the line, Don't Show Again quiet, Not Now, Import primary", () => {
  const doc = render(
    <CookieImportCard model={model} look={APP_COOKIE_IMPORT_LOOK} onChoice={() => undefined} glass={false} />,
  );
  const card = doc.querySelector(".ci-card")!;
  expect(APP_COOKIE_IMPORT_LOOK).toBe("toast");
  expect(card.textContent).toBe("Import cookies from Google ChromeDon't Show AgainNot NowImport…");
  expect(card.querySelectorAll("input, [role=checkbox]").length).toBe(0);
  expect(card.querySelector(".ci-close")).toBeNull();
  const buttons = [...card.querySelectorAll("button")];
  expect(buttons.map((b) => [b.textContent, b.getAttribute("data-role")])).toEqual([
    ["Don't Show Again", "quiet"],
    ["Not Now", "cancel"],
    ["Import…", "default"],
  ]);
  // On the app's glass the card paints none of its own.
  expect(card.classList.contains("ui-glass")).toBe(false);
  expect(card.hasAttribute("data-native-glass")).toBe(true);
});

test("every answer reaches the host as its type only", () => {
  const answers: CookieImportCommand[] = [];
  const doc = render(<CookieImportCard model={model} onChoice={(choice) => answers.push(choice)} glass={false} />);
  for (const button of doc.querySelectorAll<HTMLElement>(".ci-card button")) act(() => button.click());
  expect(answers).toEqual([{ type: "never" }, { type: "notNow" }, { type: "import" }]);
});

test("no Don't Show Again: Import and the close button", () => {
  const doc = render(<CookieImportCard model={{ ...model, neverTitle: null }} onChoice={() => undefined} />);
  expect(
    [...doc.querySelectorAll(".ci-card button")].map((b) => b.getAttribute("aria-label") ?? b.textContent),
  ).toEqual(["Not Now", "Import…"]);
});

test("the gallery's other looks keep the three answers", () => {
  for (const look of ["buttons", "stacked"] as const) {
    const answers: CookieImportCommand[] = [];
    const doc = render(<CookieImportCard model={model} look={look} onChoice={(choice) => answers.push(choice)} />);
    for (const button of doc.querySelectorAll<HTMLElement>(".ci-card button")) act(() => button.click());
    expect(answers).toEqual([{ type: "never" }, { type: "notNow" }, { type: "import" }]);
    act(() => root?.unmount());
    root = undefined;
    for (const [key, value] of saved) scope[key] = value;
    saved.clear();
    dom?.window.close();
    dom = undefined;
  }
});

test("the pushed state needs its line and answers; the icon is only an inline image; old fields are dropped", () => {
  expect(cookieImportModel({ title: "T" })).toBeNull();
  expect(cookieImportModel(null)).toBeNull();
  const read = cookieImportModel({ ...model, icon: "https://example.com/icon.png", neverTitle: "" });
  expect(read?.icon).toBeNull();
  expect(read?.neverTitle).toBeNull();
  expect(cookieImportModel(model)?.icon).toBe(model.icon);
  expect(cookieImportModel({ ...model, detail: "Nothing leaves this Mac.", keepInSyncTitle: "Keep in sync" })).toEqual(
    model,
  );
});
