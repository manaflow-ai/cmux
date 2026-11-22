// The composer's emoji lifecycle, end to end in the real Composer and editor (Leo, 2026-11-22: "for
// some reason i can't do :pleading_face: with the emoji here. we need to actually improve the
// ergonomics and lifecycle of that. there's no doubt lots of edge cases that are really good for
// ergonomics for teh emoji situation."): the list on any line of the draft, Return, Tab and a click
// to pick, the closing `:`, skin tones, Esc, another pane taking the keyboard, code, times and URLs,
// paste, input methods, caret and undo.
import { afterAll, afterEach, beforeAll, beforeEach, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act } from "react";
import type { Root } from "react-dom/client";
import { noChat, user } from "../src/gallery/fixtures/acpmux";
import { loadEmojiShortcodes } from "../src/agent-session/acpmux/emojiShortcodes";
import type { AcpmuxSnapshot } from "../src/agent-session/acpmux/model";
import type { AcpmuxSessionEntry } from "../src/agent-session/acpmux/sessionList";
import type { ComposerHandle } from "../src/agent-session/acpmux/Composer";
import type { MarkdownFieldElement, MarkdownFieldHandle } from "../src/agent-session/acpmux/MarkdownField";
import { teardownDom } from "./support/domTeardown";

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

afterAll(async () => {
  await teardownDom(saved, { window: dom.window, scope });
});

function Chips() {
  return null;
}

let chats = 0;

function chat(others: AcpmuxSessionEntry[] = []): AcpmuxSnapshot {
  const sessionId = `emoji-${++chats}`;
  return noChat(others, {
    sessionId,
    summary: { sessionId, harness: "claude", cwd: "/Users/you/src/app", turnCount: 1 },
    rows: [user("Add retries", 1)],
  });
}

/// The table in, and React's work after it done (it loads in its own chunk on the first edit).
async function settle() {
  await act(async () => {
    await loadEmojiShortcodes();
    await new Promise((resolve) => setTimeout(resolve, 5));
  });
}

async function composer(typed: string, others: AcpmuxSessionEntry[] = []) {
  const sent: string[] = [];
  let handle: ComposerHandle | null = null;
  const { createRoot } = await import("react-dom/client");
  const { Composer } = await import("../src/agent-session/acpmux/Composer");
  root ??= createRoot(host);
  const snapshot = chat(others);
  await act(async () =>
    root!.render(
      <Composer
        handle={(value) => void (handle = value)}
        snapshot={snapshot}
        sessionId={snapshot.sessionId}
        chips={Chips}
        onSend={(text) => {
          sent.push(text);
          return true;
        }}
        onStop={() => {}}
        localName="studio"
      />,
    ),
  );
  await act(async () => handle!.restore(typed, []));
  await settle();
  const field = host.querySelector<HTMLElement>("[role=combobox]")!;
  const prompt = host.querySelector<MarkdownFieldElement>(".acpmux-md-field")!.acpmuxMarkdownField!;
  return { field, prompt, sent };
}

async function type(prompt: MarkdownFieldHandle, text: string) {
  for (const letter of text) await act(async () => prompt.insertTyped(letter));
  await settle();
}

const rows = () =>
  [...host.querySelectorAll<HTMLElement>("#acpmux-emoji-menu .acpmux-emoji-row")].map((row) =>
    row.getAttribute("aria-label"),
  );

async function press(field: HTMLElement, key: string, init: KeyboardEventInit = {}) {
  await act(async () => {
    field.dispatchEvent(new window.KeyboardEvent("keydown", { key, bubbles: true, cancelable: true, ...init }));
  });
}

beforeEach(() => localStorage.removeItem("cmux.acpmux.recentEmoji"));

test("Leo's `:plead` on a later line, under a list, lists 🥺; Return writes it there and never sends", async () => {
  // His draft (2026-11-22): the list item, then `:plead` on a line of its own. The list read only
  // the first paragraph's caret, so it never opened past the first line.
  const { field, prompt, sent } = await composer(
    "ios. 1, perfect it.\n\n2. claude code has such a nice animation\n\n:plea",
  );
  await type(prompt, "d");
  expect(rows()[0]).toBe("🥺 :pleading_face:");
  expect(field.getAttribute("aria-activedescendant")).toBe("acpmux-emoji-0");
  await press(field, "Enter", { keyCode: 13 });
  expect(sent).toEqual([]);
  expect(rows()).toEqual([]);
  expect(prompt.plainText().endsWith("\n🥺 ")).toBe(true);
  expect(prompt.plainText().startsWith("ios. 1, perfect it.")).toBe(true);
});

test("Tab and a click write the highlighted row; arrows move it", async () => {
  const { field, prompt } = await composer("first line\n\nsecond");
  await type(prompt, " :sob");
  expect(rows()[0]).toBe("😭 :sob:");
  await press(field, "Tab", { keyCode: 9 });
  expect(prompt.plainText()).toBe("first line\nsecond 😭 ");
  await type(prompt, ":smi");
  const second = rows()[1]!.split(" ")[0]!;
  await press(field, "ArrowDown", { keyCode: 40 });
  expect(field.getAttribute("aria-activedescendant")).toBe("acpmux-emoji-1");
  const row = host.querySelectorAll<HTMLElement>("#acpmux-emoji-menu .acpmux-emoji-row")[1]!;
  await act(async () => {
    row.dispatchEvent(new window.MouseEvent("mousedown", { bubbles: true, cancelable: true }));
  });
  expect(prompt.plainText()).toBe(`first line\nsecond 😭 ${second} `);
});

test("a pick mid-line keeps the text after it and its space; the caret goes past the space", async () => {
  const { field, prompt } = await composer("so :ted now");
  await act(async () => prompt.setCaret("so :ted".length));
  await settle();
  expect(rows()[0]).toBe("🧸 :teddy_bear:");
  await press(field, "Enter", { keyCode: 13 });
  expect(prompt.plainText()).toBe("so 🧸 now");
  expect(prompt.caret()).toBe("so 🧸 ".length);
});

test("one ⌘Z after a pick gives back the typed `:plead`", async () => {
  const { field, prompt } = await composer("aw");
  await type(prompt, " :plead");
  await press(field, "Enter", { keyCode: 13 });
  expect(prompt.plainText()).toBe("aw 🥺 ");
  await act(async () => prompt.undo());
  expect(prompt.plainText()).toBe("aw :plead");
});

test("the `:` that closes a known code writes its emoji; ⌘Z gives back `:code:`; an unknown code stays", async () => {
  const { prompt } = await composer("aw");
  await type(prompt, " :pleading_face:");
  expect(prompt.plainText()).toBe("aw 🥺");
  expect(prompt.caret()).toBe("aw 🥺".length);
  expect(rows()).toEqual([]);
  await act(async () => prompt.undo());
  expect(prompt.plainText()).toBe("aw :pleading_face:");
  await composer("then");
  const next = host.querySelector<MarkdownFieldElement>(".acpmux-md-field")!.acpmuxMarkdownField!;
  await type(next, " :notacode: and 10:30: ok");
  expect(next.plainText()).toBe("then :notacode: and 10:30: ok");
});

test("skin tones: `:skin-tone-N:` after a toned emoji re-tones it, and the tone is remembered", async () => {
  const { prompt } = await composer("hi");
  await type(prompt, " :wave::skin-tone-4:");
  expect(prompt.plainText()).toBe("hi 👋🏽");
  await type(prompt, " :wave:");
  expect(prompt.plainText()).toBe("hi 👋🏽 👋🏽");
  await type(prompt, " :wav");
  expect(rows()[0]).toBe("👋🏽 :wave:");
});

test("Esc closes the list for that text; typing again brings it back", async () => {
  const { field, prompt } = await composer("hey");
  await type(prompt, " :smi");
  expect(rows().length).toBeGreaterThan(0);
  await press(field, "Escape", { keyCode: 27 });
  expect(rows()).toEqual([]);
  // Return now sends the text as typed.
  await type(prompt, "l");
  expect(rows().length).toBeGreaterThan(0);
});

test("the list closes when another pane takes the keyboard, and stays closed until the next edit", async () => {
  const { prompt } = await composer("hey");
  await type(prompt, " :plead");
  expect(rows()[0]).toBe("🥺 :pleading_face:");
  await act(async () => {
    window.dispatchEvent(new window.Event("blur"));
  });
  expect(rows()).toEqual([]);
  await type(prompt, "i");
  expect(rows().length).toBeGreaterThan(0);
});

test("never in code, a time or a URL", async () => {
  for (const draft of ["meet at 10:30", "see https://ex", "key:value"]) {
    await composer(draft);
    expect(rows()).toEqual([]);
  }
  // A code span: the caret right after `:smi` inside it.
  const { prompt } = await composer("run `:smi` now");
  await act(async () => prompt.setCaret("run :smi".length));
  await settle();
  expect(rows()).toEqual([]);
});

test("a paste's known `:code:`s go in as emoji, its code and URLs as pasted", async () => {
  const { prompt } = await composer("");
  // Focus loads the table, so a paste that is the first edit converts too.
  const editor = host.querySelector<HTMLElement>(".acpmux-md-field [contenteditable]")!;
  await act(async () => {
    editor.dispatchEvent(new window.FocusEvent("focusin", { bubbles: true }));
  });
  await settle();
  await act(async () => prompt.pasteText("ship it :tada: see https://x.com/:tada: :nope:"));
  expect(prompt.plainText()).toBe("ship it 🎉 see https://x.com/:tada: :nope:");
});

test("an input method's text opens the list once committed, never while it composes", async () => {
  const { prompt } = await composer("so");
  const editor = host.querySelector<HTMLElement>(".acpmux-md-field [contenteditable]")!;
  await act(async () => {
    editor.dispatchEvent(new window.CompositionEvent("compositionstart", { bubbles: true, data: "" }));
  });
  await act(async () => prompt.insertText(" :plead"));
  await settle();
  expect(rows()).toEqual([]);
  await act(async () => {
    editor.dispatchEvent(new window.CompositionEvent("compositionend", { bubbles: true, data: ":plead" }));
  });
  await settle();
  expect(rows()[0]).toBe("🥺 :pleading_face:");
});

// The @ list read the caret the same first-paragraph way, so `@` on a later line opened nothing.
const mentionRows = () => [...host.querySelectorAll<HTMLElement>("#acpmux-mention-menu [role=option]")];

test("@ on a later line lists other chats; Return writes the mention there as one undo step", async () => {
  const others = [{ sessionId: "other-chat", title: "Release checklist" }];
  const { field, prompt, sent } = await composer("first line\n\nsecond", others);
  await type(prompt, " @relea");
  expect(mentionRows().length).toBeGreaterThan(0);
  await press(field, "Enter", { keyCode: 13 });
  expect(sent).toEqual([]);
  expect(mentionRows()).toEqual([]);
  expect(prompt.plainText()).toBe('first line\nsecond cmux session "Release checklist" (other-chat) ');
  await act(async () => prompt.undo());
  expect(prompt.plainText()).toBe("first line\nsecond @relea");
});

test("@ inside a code span opens no list", async () => {
  const others = [{ sessionId: "other-chat", title: "Release checklist" }];
  await composer("run `@relea` now", others);
  const prompt = host.querySelector<MarkdownFieldElement>(".acpmux-md-field")!.acpmuxMarkdownField!;
  await act(async () => prompt.setCaret("run @relea".length));
  await settle();
  expect(mentionRows()).toEqual([]);
});
