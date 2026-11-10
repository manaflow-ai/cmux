// The omnibar star's edit bubble, now a page (Bookmarks PR 2): the native form's fields and
// buttons, each sending the bubble's draft to the host, so a dismiss saves what it shows; a page
// title that arrives after the star renames a new bookmark only while its name is unedited.
import { afterEach, expect, test } from "bun:test";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import { UiProvider } from "../../ui/UiProvider";
import type { PopupHost } from "../../ui/popupHost";
import type { NativePopupEvent, NativePopupModel, NativePopupRow } from "../../ui/popupProtocol";
import { BookmarkEditBubble, FOLDER_SEARCH_ID } from "./BookmarkEditBubble";
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
  "HTMLInputElement",
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
    HTMLInputElement: win.HTMLInputElement,
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

/** The app's popup host as the page sees it: each model it was sent, and its event listeners. */
function nativeHost() {
  const sent: NativePopupModel[] = [];
  const listeners = new Set<(event: NativePopupEvent) => void>();
  const host: PopupHost = {
    show: async () => ({ shown: false }),
    update() {},
    hide() {},
    owner: () => null,
    listen: () => () => {},
    native: {
      show: async (model) => {
        sent.push(model);
        return { shown: true };
      },
      update: (model) => void sent.push(model),
      hide() {},
      listen(listener) {
        listeners.add(listener);
        return () => listeners.delete(listener);
      },
    },
  };
  const emit = (event: Omit<NativePopupEvent, "popupId" | "revision">) => {
    const model = sent.at(-1)!;
    for (const listener of listeners) listener({ ...event, popupId: model.id, revision: model.revision });
  };
  return { host, sent, emit };
}

/** The host's own row rules (CmuxNextDesign NativePopupModel+Validation): at most 1,000 rows a
 * level, 16 levels and 4,000 identities, each identity once. */
function hostAccepts(model: NativePopupModel): boolean {
  const ids = new Set<string>(model.search ? [model.search.id] : []);
  const visit = (rows: readonly NativePopupRow[], depth: number): boolean => {
    if (depth > 16 || rows.length > 1000) return false;
    for (const row of rows) {
      if (!row.id || ids.has(row.id)) return false;
      ids.add(row.id);
      if (row.children && !visit(row.children, depth + 1)) return false;
    }
    return true;
  };
  return visit([...(model.rail ?? []), ...model.rows, ...(model.footer ?? [])], 0) && ids.size <= 4000;
}

test("a profile of 1,500 folders opens a Folder menu the host draws, and its search reaches every folder", async () => {
  const folders = [
    { id: "bar", title: "Bookmarks Bar", depth: 0 },
    ...Array.from({ length: 1500 }, (_, n) => ({ id: `bm_${n}`, title: `Folder ${n}`, depth: 1 })),
    { id: "other", title: "Other Bookmarks", depth: 0 },
  ];
  const { host, sent, emit } = nativeHost();
  const commands: BookmarkEditCommand[] = [];
  const doc = render(
    <UiProvider container={null} popupHost={host}>
      <BookmarkEditBubble
        state={{ ...state, folders }}
        strings={strings}
        onCommand={(c) => commands.push(c)}
        glass={false}
      />
    </UiProvider>,
  );
  const trigger = doc.querySelector<HTMLButtonElement>(".be-folder button")!;
  await act(async () => trigger.click());
  const opened = sent.at(-1)!;
  expect(hostAccepts(opened)).toBe(true);
  expect(opened.search?.id).toBe(FOLDER_SEARCH_ID);
  expect(opened.search?.placeholder).toBe("Search folders");
  expect(opened.rows.at(-1)?.label).toBe("Type to find more folders");
  expect(opened.rows.some((row) => row.value === "bm_1499")).toBe(false);

  // Typing narrows the rows to the folder past the first ones; picking it sends it.
  await act(async () => emit({ type: "search", id: FOLDER_SEARCH_ID, value: "folder 1499" }));
  const found = sent.at(-1)!;
  expect(hostAccepts(found)).toBe(true);
  expect(found.search?.value).toBe("folder 1499");
  const row = found.rows.find((r) => r.value === "bm_1499")!;
  expect(row.label).toBe("Folder 1499");
  expect(row.description).toBe("Bookmarks Bar");
  await act(async () => emit({ type: "pick", id: row.id }));
  expect(commands.at(-1)).toEqual({ type: "edit", title: "example.com", folder: "bm_1499" });
  expect(doc.querySelector(".ui-select-value")!.textContent).toBe("\u00a0".repeat(4) + "Folder 1499");

  // A search that finds nothing says so.
  await act(async () => trigger.click());
  await act(async () => emit({ type: "search", id: FOLDER_SEARCH_ID, value: "no such folder" }));
  expect(sent.at(-1)!.rows.map((r) => r.label)).toEqual(["No matches"]);
});
