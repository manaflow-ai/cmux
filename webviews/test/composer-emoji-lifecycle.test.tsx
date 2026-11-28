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
    await new Promise((resolve) => setTimeout(resolve, 0));
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
  // The person is typing here: only the prompt with the keyboard shows a list.
  await act(async () => prompt.focus());
  await settle();
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

test("Esc closes the list for that token: typing on and the caret away and back keep it closed", async () => {
  const { field, prompt, sent } = await composer("hey");
  await type(prompt, " :smi");
  expect(rows().length).toBeGreaterThan(0);
  await press(field, "Escape", { keyCode: 27 });
  expect(rows()).toEqual([]);
  // More letters on the same token: still closed, and Return sends the text as typed.
  await type(prompt, "l");
  expect(rows()).toEqual([]);
  await act(async () => prompt.setCaret(1));
  await act(async () => prompt.setCaret("hey :smil".length));
  await settle();
  expect(rows()).toEqual([]);
  await press(field, "Enter", { keyCode: 13 });
  expect(sent).toEqual(["hey :smil"]);
});

test("after Esc, Backspace on the token or a new token opens the list again", async () => {
  const { field, prompt } = await composer("hey");
  await type(prompt, " :smil");
  await press(field, "Escape", { keyCode: 27 });
  expect(rows()).toEqual([]);
  // Backspace (jsdom has no native deletion: the same edit, one character off the token).
  await act(async () => void prompt.replaceBeforeCaret(1, ""));
  await settle();
  expect(prompt.plainText()).toBe("hey :smi");
  expect(rows().length).toBeGreaterThan(0);
  await press(field, "Escape", { keyCode: 27 });
  await type(prompt, " :sob");
  expect(rows()[0]).toBe("😭 :sob:");
});

test("the caret moved off the token closes the list; back on it, the list shows", async () => {
  const { prompt } = await composer("hey there");
  await type(prompt, " :plead");
  expect(rows()[0]).toBe("🥺 :pleading_face:");
  await act(async () => prompt.setCaret(2));
  await settle();
  expect(rows()).toEqual([]);
  await act(async () => prompt.setCaret("hey there :plead".length));
  await settle();
  expect(rows()[0]).toBe("🥺 :pleading_face:");
});

test("the list closes when another pane takes the keyboard, and shows again back in the prompt", async () => {
  const { prompt } = await composer("hey");
  await type(prompt, " :plead");
  expect(rows()[0]).toBe("🥺 :pleading_face:");
  await act(async () => {
    window.dispatchEvent(new window.Event("blur"));
  });
  expect(rows()).toEqual([]);
  // The window back (the element stayed focused): the list shows again at the same caret.
  await act(async () => {
    window.dispatchEvent(new window.Event("focus"));
  });
  await settle();
  expect(rows()[0]).toBe("🥺 :pleading_face:");
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

// The @ list's built-in tools show in any chat (toolMentions.ts), so `@brow` lists Browser use.
test("@ on a later line lists its rows; Return writes the mention there as one undo step", async () => {
  const { field, prompt, sent } = await composer("first line\n\nsecond");
  await type(prompt, " @brow");
  expect(mentionRows().length).toBeGreaterThan(0);
  await press(field, "Enter", { keyCode: 13 });
  expect(sent).toEqual([]);
  expect(mentionRows()).toEqual([]);
  expect(prompt.plainText()).toBe("first line\nsecond @browser-use ");
  await act(async () => prompt.undo());
  expect(prompt.plainText()).toBe("first line\nsecond @brow");
});

test("@ inside a code span opens no list", async () => {
  await composer("run `@brow` now");
  const prompt = host.querySelector<MarkdownFieldElement>(".acpmux-md-field")!.acpmuxMarkdownField!;
  await act(async () => prompt.setCaret("run @brow".length));
  await settle();
  expect(mentionRows()).toEqual([]);
});

// Leo's two panes (2026-11-22): he typed `:plead` at the end of a long draft in the left pane; the
// right pane, whose own draft also ended in `:plead`, drew the list, and Return in the left pane
// wrote nothing. The list belongs to the prompt with the keyboard, at its own caret.
test("two panes: only the focused prompt lists, and Return writes there, on the last line of a long draft", async () => {
  const { createRoot } = await import("react-dom/client");
  const { Composer } = await import("../src/agent-session/acpmux/Composer");
  root ??= createRoot(host);
  const left = chat();
  const right = chat();
  const handles: Record<string, ComposerHandle> = {};
  const sent: string[] = [];
  const pane = (snapshot: AcpmuxSnapshot, name: string) => (
    <div data-pane={name}>
      <Composer
        handle={(value) => void (value && (handles[name] = value))}
        snapshot={snapshot}
        sessionId={snapshot.sessionId}
        chips={Chips}
        onSend={(text) => {
          sent.push(text);
          return true;
        }}
        onStop={() => {}}
        localName="studio"
      />
    </div>
  );
  await act(async () =>
    root!.render(
      <>
        {pane(left, "left")}
        {pane(right, "right")}
      </>,
    ),
  );
  const long = [
    "ios. 1, a message that should never be shown to me. figure out the right behaviour we want, perfect it.",
    "",
    "2. claude code has such a nice animation on startup... it's so smooth and nice...",
    "",
    ":plea",
  ].join("\n");
  await act(async () => handles.right!.restore(":plead", []));
  await act(async () => handles.left!.restore(long, []));
  await settle();
  const promptOf = (name: string) =>
    host.querySelector<MarkdownFieldElement>(`[data-pane=${name}] .acpmux-md-field`)!.acpmuxMarkdownField!;
  // Nothing focused yet: the right pane's restored `:plead` draws no list.
  expect(host.querySelectorAll("#acpmux-emoji-menu").length).toBe(0);
  const leftPrompt = promptOf("left");
  await act(async () => leftPrompt.focus());
  await type(leftPrompt, "d");
  const menus = [...host.querySelectorAll<HTMLElement>("#acpmux-emoji-menu")];
  expect(menus.length).toBe(1);
  expect(menus[0]!.closest("[data-pane]")!.getAttribute("data-pane")).toBe("left");
  expect(rows()[0]).toBe("🥺 :pleading_face:");
  const field = host.querySelector<HTMLElement>("[data-pane=left] [role=combobox]")!;
  await press(field, "Enter", { keyCode: 13 });
  expect(sent).toEqual([]);
  expect(leftPrompt.plainText().endsWith("\n🥺 ")).toBe(true);
  expect(promptOf("right").plainText()).toBe(":plead");
  // The keyboard to the right pane: the left list stays shut, and the right one opens once typed on.
  await type(leftPrompt, ":sob");
  expect(rows()[0]).toBe("😭 :sob:");
  const rightPrompt = promptOf("right");
  await act(async () => rightPrompt.focus());
  await settle();
  expect(host.querySelector("[data-pane=left] #acpmux-emoji-menu")).toBeNull();
  await type(rightPrompt, "i");
  expect(host.querySelectorAll("#acpmux-emoji-menu").length).toBe(1);
  expect(host.querySelector("[data-pane=right] #acpmux-emoji-menu")).not.toBeNull();
});
