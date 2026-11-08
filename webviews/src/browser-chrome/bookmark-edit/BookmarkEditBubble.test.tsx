// The omnibar star's edit bubble, now a page (Bookmarks PR 2): the native form's fields and
// buttons, each sending the bubble's draft to the host, so a dismiss saves what it shows; a page
// title that arrives after the star renames a new bookmark only while its name is unedited.
import { afterEach, expect, test } from "bun:test";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import { BookmarkEditBubble } from "./BookmarkEditBubble";
import type { BookmarkEditCommand, BookmarkEditState } from "./model";
import { bookmarkEditStrings } from "./strings";

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
    // Base UI schedules some state on a frame.
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

const state: BookmarkEditState = {
  revision: 1,
  isNew: true,
  title: "example.com",
  folder: "bar",
  folders: [
    { id: "bar", title: "Bookmarks Bar", depth: 0 },
    { id: "other", title: "Other Bookmarks", depth: 0 },
  ],
  width: 320,
};
const strings = bookmarkEditStrings(["en"]);

function type(doc: Document, value: string) {
  const input = doc.querySelector<HTMLInputElement>(".be-name")!;
  const setter = Object.getOwnPropertyDescriptor(doc.defaultView!.HTMLInputElement.prototype, "value")!.set!;
  act(() => {
    setter.call(input, value);
    input.dispatchEvent(new doc.defaultView!.Event("input", { bubbles: true }));
  });
}

test("the card says Bookmark Added for a new bookmark, with its name and folder, the name focused", () => {
  const doc = render(<BookmarkEditBubble state={state} strings={strings} onCommand={() => undefined} glass={false} />);
  expect(doc.querySelector(".be-title")!.textContent).toBe("Bookmark Added");
  expect(doc.querySelector<HTMLInputElement>(".be-name")!.value).toBe("example.com");
  expect(doc.querySelector(".ui-select-value")!.textContent).toBe("Bookmarks Bar");
  expect(doc.activeElement).toBe(doc.querySelector(".be-name"));
  const buttons = [...doc.querySelectorAll<HTMLButtonElement>(".be-actions button")];
  expect(buttons.map((b) => b.textContent)).toEqual(["More…", "Remove", "Done↩"]);
});

test("every edit and button sends the draft", () => {
  const sent: BookmarkEditCommand[] = [];
  const doc = render(
    <BookmarkEditBubble state={state} strings={strings} onCommand={(c) => sent.push(c)} glass={false} />,
  );
  type(doc, "Example");
  for (const button of doc.querySelectorAll<HTMLElement>(".be-actions button")) act(() => button.click());
  expect(sent.map((c) => c.type)).toEqual(["edit", "more", "remove", "done"]);
  expect(sent.every((c) => c.title === "Example" && c.folder === "bar")).toBe(true);
});

test("a later title renames the bookmark only while its name is unedited", () => {
  const doc = render(<BookmarkEditBubble state={state} strings={strings} onCommand={() => undefined} glass={false} />);
  act(() =>
    root!.render(
      <BookmarkEditBubble
        state={{ ...state, revision: 2, title: "Example Domain" }}
        strings={strings}
        onCommand={() => undefined}
        glass={false}
      />,
    ),
  );
  expect(doc.querySelector<HTMLInputElement>(".be-name")!.value).toBe("Example Domain");
  type(doc, "Mine");
  act(() =>
    root!.render(
      <BookmarkEditBubble
        state={{ ...state, revision: 3, title: "Other" }}
        strings={strings}
        onCommand={() => undefined}
        glass={false}
      />,
    ),
  );
  expect(doc.querySelector<HTMLInputElement>(".be-name")!.value).toBe("Mine");
});
