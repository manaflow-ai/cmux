// l10n-allow-file: test fixture prompts, not shipped UI.
// A known cmux link in the draft is a chip that acts as one character (Leo, 2026-11-09: "when I do
// these links that I copy, the caret sort of disappears on it, and then after I paste in another
// thing, it just becomes unformatted again, and I can't, like, sort of, like, return it back to the
// formatted view of it"): the link's text is hidden beside a chip that takes no input, so the caret
// at either end stands outside it (composer-chip-caret.browser.test.ts measures the painted caret);
// a paste, a typed word, an attachment or a second link right after it leaves a space so it stays a
// chip; ArrowLeft and ArrowRight step over it; Backspace and Delete take it whole. And the chat
// composer takes typing while a Cloud start is out (Leo: "I can't click into the composer at all to,
// like potentially type other stuff while it's doing that initial load situation").
import { afterAll, afterEach, beforeAll, beforeEach, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act } from "react";
import type { Root } from "react-dom/client";
import { noChat, user } from "../src/gallery/fixtures/acpmux";
import type { AcpmuxSnapshot } from "../src/agent-session/acpmux/model";
import type { ComposerHandle } from "../src/agent-session/acpmux/Composer";
import type { MarkdownFieldElement } from "../src/agent-session/acpmux/MarkdownField";
import { setLinkPlaces } from "../src/agent-session/acpmux/chips/cmuxLinkPlaces";
import { deeplinks } from "../src/agent-session/acpmux/composer/deeplinks";

const HEX = "16c92e4354fcaf05540386720d78e251";
const WORKSPACE = `cmux-nightly://workspace/ws_${HEX}`;

const scope = globalThis as Record<string, unknown>;
const keys = [
  "window",
  "document",
  "navigator",
  "HTMLElement",
  "IS_REACT_ACT_ENVIRONMENT",
  "Node",
  "Element",
  "MutationObserver",
  "ResizeObserver",
  "getComputedStyle",
  "requestAnimationFrame",
  "cancelAnimationFrame",
  "localStorage",
  "KeyboardEvent",
  "InputEvent",
  "MouseEvent",
  "CompositionEvent",
] as const;
const saved = keys.map((key) => [key, key in scope, scope[key]] as const);
let dom: JSDOM;
let root: Root | undefined;
let host: HTMLElement;

beforeAll(() => {
  dom = new JSDOM("<!doctype html><div id=root></div>", {
    pretendToBeVisual: true,
    url: "https://cmux.test/",
  });
  const { window } = dom;
  Object.assign(scope, {
    ResizeObserver: class {
      observe() {}
      unobserve() {}
      disconnect() {}
    },
    window,
    document: window.document,
    navigator: window.navigator,
    HTMLElement: window.HTMLElement,
    IS_REACT_ACT_ENVIRONMENT: true,
    Node: window.Node,
    Element: window.Element,
    MutationObserver: window.MutationObserver,
    getComputedStyle: window.getComputedStyle.bind(window),
    requestAnimationFrame: (run: (time: number) => void) => setTimeout(() => run(0), 0),
    cancelAnimationFrame: (id: number) => clearTimeout(id),
    localStorage: window.localStorage,
    KeyboardEvent: window.KeyboardEvent,
    InputEvent: window.InputEvent,
    MouseEvent: window.MouseEvent,
    CompositionEvent: window.CompositionEvent,
  });
  // jsdom lays nothing out: a range has no boxes, which ProseMirror reads to scroll the caret into view.
  const box = { top: 0, bottom: 0, left: 0, right: 0, width: 0, height: 0, x: 0, y: 0 };
  Object.assign(window.Range.prototype, { getClientRects: () => [], getBoundingClientRect: () => box });
  host = window.document.getElementById("root")!;
});

afterEach(() => {
  act(() => root?.unmount());
  root = undefined;
  host.replaceChildren();
});

afterAll(() => {
  dom.window.close();
  for (const [key, had, value] of saved) {
    if (had) scope[key] = value;
    else delete scope[key];
  }
});

beforeEach(() => setLinkPlaces([{ id: `ws_${HEX}`, kind: "workspace", title: "workspace-413" }]));

let chats = 0;

function chat(): AcpmuxSnapshot {
  const sessionId = `chip-caret-${++chats}`;
  return noChat([], {
    sessionId,
    summary: { sessionId, harness: "claude", cwd: "/Users/you/src/app", turnCount: 1 },
    rows: [user("Add retries", 1)],
  });
}

async function composer(typed: string, locked = false) {
  const sent: string[] = [];
  let handle: ComposerHandle | null = null;
  const snapshot = chat();
  const { createRoot } = await import("react-dom/client");
  const { Composer } = await import("../src/agent-session/acpmux/Composer");
  root ??= createRoot(host);
  await act(async () =>
    root!.render(
      <Composer
        handle={(value) => void (handle = value)}
        snapshot={snapshot}
        sessionId={snapshot.sessionId}
        chips={() => null}
        onSend={(text) => {
          sent.push(text);
          return true;
        }}
        onStop={() => {}}
        localName="studio"
        locked={locked}
      />,
    ),
  );
  await act(async () => handle!.restore(typed, []));
  const field = host.querySelector<HTMLElement>("[role=combobox]")!;
  const md = host.querySelector<MarkdownFieldElement>(".acpmux-md-field")!.acpmuxMarkdownField!;
  return { field, md, sent };
}

const chips = () => [...host.querySelectorAll<HTMLElement>(".acpmux-md .is-titled[data-title]")];

const key = (field: HTMLElement, name: string, extra: KeyboardEventInit = {}) =>
  act(async () => {
    field.dispatchEvent(new window.KeyboardEvent("keydown", { key: name, bubbles: true, cancelable: true, ...extra }));
  });

test("the chip takes no input and its link's text is hidden beside it, never under it at no size", async () => {
  await composer(`See ${WORKSPACE}`);
  const [chip] = chips();
  expect(chip?.dataset.title).toBe("workspace-413");
  expect(chip?.getAttribute("contenteditable")).toBe("false");
  // The chip holds no text: the caret can never land in it.
  expect(chip?.textContent).toBe("");
  expect(host.querySelector(".acpmux-md .is-titled-link")?.textContent).toBe(WORKSPACE);
});

test("a second link pasted right after a chip keeps both chips, a space between", async () => {
  const { md } = await composer(`See ${WORKSPACE}`);
  await act(async () => md.setCaret(`See ${WORKSPACE}`.length));
  await act(async () => md.pasteText(WORKSPACE));
  expect(md.plainText()).toBe(`See ${WORKSPACE} ${WORKSPACE}`);
  expect(chips().length).toBe(2);
  expect(md.caret()).toBe(`See ${WORKSPACE} ${WORKSPACE}`.length);
});

test("text pasted or typed right after a chip, or before it, never turns it back into its URL", async () => {
  const { md } = await composer(`See ${WORKSPACE}`);
  await act(async () => md.setCaret(`See ${WORKSPACE}`.length));
  await act(async () => md.pasteText("hello"));
  expect(md.plainText()).toBe(`See ${WORKSPACE} hello`);
  expect(chips().length).toBe(1);
  expect(md.caret()).toBe(`See ${WORKSPACE} hello`.length);
  await act(async () => md.insertTyped("!"));
  expect(md.plainText()).toBe(`See ${WORKSPACE} hello!`);
  // Typed against its start: the space goes after the typed word, the caret stays at the word's end.
  await act(async () => md.setCaret("See ".length));
  await act(async () => md.insertTyped("x"));
  expect(md.plainText()).toBe(`See x ${WORKSPACE} hello!`);
  expect(md.caret()).toBe("See x".length);
  expect(chips().length).toBe(1);
  // Sentence punctuation after it is no part of the link: no space comes.
  await act(async () => md.setCaret(`See x ${WORKSPACE}`.length));
  await act(async () => md.insertTyped("."));
  expect(md.plainText()).toBe(`See x ${WORKSPACE}. hello!`);
  expect(chips().length).toBe(1);
});

test("an attachment (or any leaf) right after a link ends the link", () => {
  const text = `See ${WORKSPACE}\uFFFCimg\uFFFC`;
  expect(deeplinks(text).map((link) => text.slice(link.start, link.end))).toEqual([WORKSPACE]);
  expect(deeplinks(`\uFFFC${WORKSPACE}`).length).toBe(1);
});

test("ArrowLeft and ArrowRight step over a chip as one character; Shift extends across it", async () => {
  const { field, md } = await composer(`See ${WORKSPACE} now`);
  const after = `See ${WORKSPACE}`.length;
  await act(async () => md.setCaret(after));
  await key(field, "ArrowLeft");
  expect(md.caret()).toBe("See ".length);
  expect(chips().length).toBe(1);
  await key(field, "ArrowRight");
  expect(md.caret()).toBe(after);
  await act(async () => md.setCaret("See ".length));
  await key(field, "ArrowRight", { shiftKey: true });
  expect(md.text()).toMatchObject({ selectionStart: "See ".length, selectionEnd: after });
  expect(chips().length).toBe(1);
});

test("Backspace after a chip and Delete before it take the whole link", async () => {
  const { field, md } = await composer(`See ${WORKSPACE} now`);
  await act(async () => md.setCaret(`See ${WORKSPACE}`.length));
  await key(field, "Backspace");
  expect(md.plainText()).toBe("See  now");
  expect(chips().length).toBe(0);
  const again = await composer(`See ${WORKSPACE} now`);
  await act(async () => again.md.setCaret("See ".length));
  await key(again.field, "Delete");
  expect(again.md.plainText()).toBe("See  now");
});

test("while a Cloud start is out the chat composer takes typing, and Send keeps the draft", async () => {
  const { field, md, sent } = await composer("", true);
  expect(host.querySelector(".acpmux-composer-box")?.hasAttribute("inert")).toBe(false);
  expect(host.querySelector(".acpmux-composer [inert] [role=combobox]")).toBeNull();
  await act(async () => md.focus());
  await act(async () => md.insertTyped("and also the tests"));
  expect(md.plainText()).toBe("and also the tests");
  await key(field, "Enter", { keyCode: 13 });
  expect(sent).toEqual([]);
  expect(md.plainText()).toBe("and also the tests");
});
