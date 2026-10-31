// Leo 2026-10-21, as in Claude: a huge paste (more than 20 lines or 2,000 characters) into the
// composer is a "Pasted text" chip (its first words and line count), not pages of text in the
// prompt. A click puts it back in the prompt to edit, × removes it, and it goes to the agent as
// its own text block after the prompt's. Paste as Plain Text (⌘⇧V, or the prompt's menu) keeps
// the raw paste, and a paste under the limit goes in as before (#22789).
import { afterAll, afterEach, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act, createRef, type RefObject } from "react";
import type { Root } from "react-dom/client";
import { noChat } from "../src/gallery/fixtures/acpmux";
import type { ComposerEditCommand, ComposerHandle } from "../src/agent-session/acpmux/Composer";
import {
  inlineTokenIds,
  promptBlocks,
  withoutInlineTokens,
  type ComposerAttachment,
} from "../src/agent-session/acpmux/attachments";
import type { MarkdownFieldElement } from "../src/agent-session/acpmux/MarkdownField";
import {
  PASTE_CHIP_CHARS,
  PASTE_CHIP_LINES,
  isLargePaste,
  pastedTextAttachment,
  resentAttachments,
  shownPrompt,
} from "../src/agent-session/acpmux/pastedText";
import { keptChips } from "../src/agent-session/acpmux/composer/keptAttachments";
import {
  DEFAULT_COMPOSER,
  setComposerSettings,
  type AttachmentView,
} from "../src/agent-session/acpmux/composerSettings";

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
] as const;
const saved = keys.map((key) => [key, key in scope, scope[key]] as const);
let dom: JSDOM;
let root: Root | undefined;
let host: HTMLElement;

beforeAll(() => {
  dom = new JSDOM("<!doctype html><div id=root></div>", { pretendToBeVisual: true, url: "https://cmux.test/" });
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
  });
  // jsdom lays nothing out and its Range has no rects: ProseMirror measures one to scroll a paste
  // into view (a chip's text going back into the prompt goes in as a paste). An empty box will do.
  const box = () => ({ left: 0, top: 0, right: 0, bottom: 0, width: 0, height: 0, x: 0, y: 0, toJSON: () => ({}) });
  Object.assign(window.Range.prototype, {
    getClientRects: () => Object.assign([box()], { item: () => box() }),
    getBoundingClientRect: box,
  });
  host = window.document.getElementById("root")!;
});

afterEach(() => {
  act(() => root?.unmount());
  root = undefined;
  host.replaceChildren();
  // Every test opens chat "chat-a": its saved draft (composerDraft.ts, the page's localStorage
  // remount cache) would come back in the next test's prompt.
  dom.window.localStorage.clear();
  setComposerSettings({ attachmentView: DEFAULT_COMPOSER.attachmentView });
});

afterAll(() => {
  dom.window.close();
  for (const [key, had, value] of saved) {
    if (had) scope[key] = value;
    else delete scope[key];
  }
});

function Chips() {
  return null;
}

type Sent = { text: string; attachments: ComposerAttachment[] };

async function openComposer(sent: Sent[] = [], onEdit?: (command: ComposerEditCommand) => void) {
  const { createRoot } = await import("react-dom/client");
  const { Composer } = await import("../src/agent-session/acpmux/Composer");
  const handle = createRef<ComposerHandle>();
  const snapshot = noChat([], {
    sessionId: "chat-a",
    summary: { sessionId: "chat-a", harness: "claude", cwd: "/Users/you/src/app", turnCount: 0 },
  });
  root ??= createRoot(host);
  await act(async () =>
    root!.render(
      <Composer
        snapshot={snapshot}
        sessionId="chat-a"
        chips={Chips}
        onSend={(text, attachments) => {
          sent.push({ text, attachments: attachments ?? [] });
          return true;
        }}
        onStop={() => {}}
        onProject={() => {}}
        onNewChat={() => {}}
        {...(onEdit ? { onEdit } : {})}
        // A pasted file goes to the chat's host and its chip is the saved path (#24652): the
        // session gets the file by path, never its contents inline.
        upload={async (files) => ({ paths: files.map((file) => `/session/uploads/${file.name}`) })}
        localName="studio"
        projectChoices={[{ cwd: "/Users/you/src/app", label: "app" }]}
        handle={handle}
      />,
    ),
  );
  // The editor is made asynchronously; its element takes the combobox role once it is.
  await until(() => !!host.querySelector('[role="combobox"]'), "the editor");
  return handle;
}

/// Yields to React until `ready()` holds; fails after 2 s with what it waited for.
async function until(ready: () => boolean, what: string) {
  const deadline = performance.now() + 2_000;
  while (!ready()) {
    if (performance.now() > deadline) throw new Error(`timed out waiting for ${what}`);
    await settle();
  }
}

/// One macrotask for React and the field to finish what an event started.
const settle = () =>
  act(async () => {
    await new Promise((resolve) => setTimeout(resolve, 0));
  });

const field = () => host.querySelector<HTMLElement>('[role="combobox"]')!;
const markdownField = () => host.querySelector<MarkdownFieldElement>(".acpmux-md-field")!.acpmuxMarkdownField!;
const chips = (handle: RefObject<ComposerHandle | null>) => handle.current!.wakeState().attachments ?? [];
/// The prompt's own words: its text without the attachments placed in it (their chips draw names).
const words = () => {
  const copy = field().cloneNode(true) as HTMLElement;
  for (const node of copy.querySelectorAll("[data-inline-attachment]")) node.remove();
  return copy.textContent ?? "";
};
/// The attachments placed in the prompt, by id, in its order.
const placed = () =>
  [...field().querySelectorAll<HTMLElement>("[data-inline-attachment]")].map((node) => node.dataset.inlineAttachment);
/// Settings' attachment view: the default draws each attachment where it sits in the prompt; the strip
/// view draws them all in the strip and keeps their places in the text (inlineAttachments.tsx).
const showAttachments = (view: AttachmentView) => act(async () => setComposerSettings({ attachmentView: view }));

/// Pastes plain text on the prompt field as WebKit delivers it: one ClipboardEvent with its data.
async function paste(plain: string, files: File[] = []) {
  const data = {
    files,
    types: [...(files.length ? ["Files"] : []), ...(plain ? ["text/plain"] : [])],
    getData: (type: string) => (type === "text/plain" ? plain : ""),
  };
  const event = new dom.window.Event("paste", { bubbles: true, cancelable: true });
  Object.defineProperty(event, "clipboardData", { value: data });
  await act(async () => {
    field().dispatchEvent(event);
  });
  await settle();
}

async function typeDraft(text: string) {
  await act(async () => {
    markdownField().focus();
    markdownField().insertTyped(text);
  });
}

/// 25 lines of a log: over the 20-line limit, under 2,000 characters.
const LOG = Array.from({ length: 25 }, (_, index) => `line ${index + 1} of the build log`).join("\n");
/// The log with a blank line in it, which a paste keeps.
const SPACED = LOG.replace("line 13 of the build log\n", "line 13 of the build log\n\n");

const plainPasteKey = (init: KeyboardEventInit) =>
  act(async () => {
    field().dispatchEvent(
      new dom.window.KeyboardEvent("keydown", {
        metaKey: true,
        shiftKey: true,
        bubbles: true,
        cancelable: true,
        ...init,
      }),
    );
  });

test("a paste over 20 lines is a Pasted text chip; the prompt keeps what was typed", async () => {
  const composer = await openComposer();
  await typeDraft("why does this fail?");
  await paste(LOG);
  const held = chips(composer);
  expect(held.map((chip) => chip.kind)).toEqual(["pasted"]);
  expect(held[0]!.text).toBe(LOG);
  // The chip goes in at the caret, after the words, and draws its first words there.
  expect(words()).toBe("why does this fail?");
  expect(placed()).toEqual([held[0]!.id]);
  const chip = field().querySelector("[data-inline-attachment] .acpmux-md-inline-chip")!;
  expect(chip).not.toBeNull();
  expect(chip.textContent).toContain("line 1 of the build log");
  // The strip view draws the same chip in the strip, its first words and its line count.
  await showAttachments("strip");
  const strip = host.querySelector(".acpmux-attachment-pasted")!;
  expect(strip).not.toBeNull();
  expect(strip.textContent).toContain("line 1 of the build log");
  expect(strip.textContent).toContain("25 lines");
  expect(words()).toBe("why does this fail?");
});

test("a paste over 2,000 characters on one line is a chip too", async () => {
  const composer = await openComposer();
  const long = "word ".repeat(450);
  await paste(long);
  expect(chips(composer).map((chip) => chip.kind)).toEqual(["pasted"]);
  expect(words()).toBe("");
  expect(placed()).toEqual([chips(composer)[0]!.id]);
});

test("a paste under the limit goes into the prompt as text, no chip", async () => {
  const composer = await openComposer();
  const short = Array.from({ length: 5 }, (_, index) => `short line ${index + 1}`).join("\n");
  await paste(short);
  expect(chips(composer)).toEqual([]);
  expect(field().textContent).toContain("short line 1");
  expect(field().textContent).toContain("short line 5");
});

test("Paste as Plain Text (⌘⇧V) keeps a large paste as raw text in the prompt", async () => {
  const composer = await openComposer();
  await act(async () => {
    field().dispatchEvent(
      new dom.window.KeyboardEvent("keydown", {
        key: "V",
        metaKey: true,
        shiftKey: true,
        bubbles: true,
        cancelable: true,
      }),
    );
  });
  await paste(LOG);
  expect(chips(composer)).toEqual([]);
  expect(field().textContent).toContain("line 25 of the build log");
  // The next ordinary paste is a chip again.
  await paste(LOG);
  expect(chips(composer).map((chip) => chip.kind)).toEqual(["pasted"]);
});

/// A pasted chip's ×, and the button that opens its text, as the view draws them.
const chipButtons = (view: AttachmentView) =>
  view === "inline"
    ? {
        remove: () => field().querySelector<HTMLButtonElement>("[data-inline-attachment] .acpmux-md-inline-remove"),
        open: () => field().querySelector<HTMLButtonElement>("[data-inline-attachment] .acpmux-md-inline-retry"),
      }
    : {
        remove: () => host.querySelector<HTMLButtonElement>(".acpmux-attachment-pasted .acpmux-attachment-remove"),
        open: () => host.querySelector<HTMLButtonElement>(".acpmux-attachment-pasted-open"),
      };

test.each(["inline", "strip"] as const)("× removes the chip and puts nothing in the prompt (%s view)", async (view) => {
  const composer = await openComposer();
  await showAttachments(view);
  await paste(LOG);
  const remove = chipButtons(view).remove()!;
  expect(remove).not.toBeNull();
  await act(async () => remove.click());
  expect(chips(composer)).toEqual([]);
  expect(host.querySelector(".acpmux-attachment-pasted")).toBeNull();
  expect(placed()).toEqual([]);
  expect(field().textContent).toBe("");
});

test.each(["inline", "strip"] as const)(
  "a click on the chip puts its text back in the prompt to edit, exactly as pasted, and the chip goes (%s view)",
  async (view) => {
    const sent: Sent[] = [];
    const composer = await openComposer(sent);
    await showAttachments(view);
    await paste(SPACED);
    const open = chipButtons(view).open()!;
    expect(open).not.toBeNull();
    await act(async () => open.click());
    expect(chips(composer)).toEqual([]);
    expect(placed()).toEqual([]);
    expect(field().textContent).toContain("line 1 of the build log");
    expect(field().textContent).toContain("line 25 of the build log");
    // The same text a raw paste gives: its lines and its blank line, nothing between the others.
    expect(markdownField().agentText(markdownField().value())).toBe(SPACED);
    await act(async () => {
      composer.current!.send();
    });
    expect(sent.map((prompt) => prompt.text)).toEqual([SPACED]);
  },
);

// Review (Codex): a chip between words opened its text at the caret, so a caret after the words put
// the text after them and changed the prompt's order. It goes where the chip was.
test.each(["inline", "strip"] as const)(
  "a click on a chip between words puts its text at the chip's place, not at the caret (%s view)",
  async (view) => {
    const composer = await openComposer();
    await showAttachments(view);
    await typeDraft("before ");
    await paste(LOG);
    await typeDraft(" after");
    expect(placed()).toEqual([chips(composer)[0]!.id]);
    // The caret is after " after", past the chip.
    await act(async () => chipButtons(view).open()!.click());
    expect(chips(composer)).toEqual([]);
    expect(placed()).toEqual([]);
    expect(markdownField().agentText(markdownField().value())).toBe(`before ${LOG} after`);
  },
);

// Review (Codex): opening a chip dropped its text before its node left the prompt, so an undo
// brought back an empty node and the paste was missing from the send. The undo brings the chip back
// with its text.
test.each(["inline", "strip"] as const)(
  "undo after opening a chip brings the chip back with its text (%s view)",
  async (view) => {
    const sent: Sent[] = [];
    const composer = await openComposer(sent);
    await showAttachments(view);
    await typeDraft("before ");
    await paste(LOG);
    await typeDraft(" after");
    const id = chips(composer)[0]!.id;
    await act(async () => chipButtons(view).open()!.click());
    expect(chips(composer)).toEqual([]);
    // One undo: the open alone, never the typing before it.
    await act(async () => markdownField().undo());
    await settle();
    expect(placed()).toEqual([id]);
    expect(chips(composer).map((chip) => [chip.id, chip.kind, chip.text])).toEqual([[id, "pasted", LOG]]);
    expect(words().replace(/\s+/g, " ")).toBe("before after");
    await act(async () => {
      composer.current!.send();
    });
    expect(sent).toHaveLength(1);
    expect(sent[0]!.attachments.map((chip) => [chip.id, chip.text])).toEqual([[id, LOG]]);
  },
);

test("Paste as Plain Text by the key's position (a non-Latin layout) keeps the paste raw too", async () => {
  const composer = await openComposer();
  await plainPasteKey({ key: "м", code: "KeyV" });
  await paste(LOG);
  expect(chips(composer)).toEqual([]);
});

test("Paste as Plain Text of only a file leaves no raw paste armed for the next text paste", async () => {
  const composer = await openComposer();
  await plainPasteKey({ key: "v", code: "KeyV" });
  await paste("", [new File(["notes"], "notes.txt", { type: "text/plain" })]);
  await paste(LOG);
  expect(chips(composer).map((chip) => chip.kind)).toEqual(["link", "pasted"]);
});

test("a bubble shows a pasted chip's text as the echo will; a resend never sends the paste twice", () => {
  const chip = pastedTextAttachment(LOG);
  const file: ComposerAttachment = { id: "f", kind: "text", name: "a.txt", mimeType: "text/plain", size: 1, text: "a" };
  // acpmux joins a prompt's text blocks with a newline (hub/session.rs prompt_text).
  // Each paste's range is the one the echo's user_message.pasted names, so the bubble's chip is
  // there from the send on.
  expect(shownPrompt("why?", [chip])).toEqual({ text: `why?\n${LOG}`, pasted: [{ start: 5, end: 5 + LOG.length }] });
  expect(shownPrompt("", [chip, chip])).toEqual({
    text: `${LOG}\n${LOG}`,
    pasted: [
      { start: 0, end: LOG.length },
      { start: LOG.length + 1, end: 2 * LOG.length + 1 },
    ],
  });
  expect(shownPrompt("why?", [])).toEqual({ text: "why?", pasted: [] });
  // Retry and Edit send the echoed text, which has the paste in it: the chip stays out.
  expect(resentAttachments([chip, file])).toEqual([file]);
});

test("the pasted text goes to the agent as its own text block after the prompt's, marked pasted", async () => {
  const sent: Sent[] = [];
  const composer = await openComposer(sent);
  await typeDraft("why does this fail?");
  await paste(LOG);
  await act(async () => {
    composer.current!.send();
  });
  expect(sent).toHaveLength(1);
  // The prompt places the chip where it was pasted, after the words.
  expect(withoutInlineTokens(sent[0]!.text)).toBe("why does this fail?");
  expect(inlineTokenIds(sent[0]!.text)).toEqual([sent[0]!.attachments[0]!.id]);
  expect(sent[0]!.attachments.map((chip) => chip.kind)).toEqual(["pasted"]);
  expect(promptBlocks(sent[0]!.text, sent[0]!.attachments)).toEqual([
    { type: "text", text: "why does this fail?" },
    { type: "text", text: LOG, _meta: { cmux: { pasted: true } } },
  ]);
  // A chip sent alone still goes, as its own block.
  expect(promptBlocks("", sent[0]!.attachments)).toEqual([
    { type: "text", text: LOG, _meta: { cmux: { pasted: true } } },
  ]);
});

test("the limit: more than 20 lines or 2,000 characters; the label is the first words on one line", () => {
  expect(PASTE_CHIP_LINES).toBe(20);
  expect(PASTE_CHIP_CHARS).toBe(2000);
  const lines = (count: number) => Array.from({ length: count }, (_, index) => `l${index}`).join("\n");
  expect(isLargePaste(lines(20))).toBe(false);
  // A newline at the end starts no line.
  expect(isLargePaste(`${lines(20)}\n`)).toBe(false);
  expect(isLargePaste(lines(21))).toBe(true);
  expect(isLargePaste("x".repeat(2000))).toBe(false);
  expect(isLargePaste("x".repeat(2001))).toBe(true);
  // Its name is the transcript chip's (promptCollapse.ts pasteName): the first words, one line.
  expect(pastedTextAttachment("\n  first   line\nsecond line  ").name).toBe("first line");
});

test("a pasted chip is kept with the chat's unsent chips, its text with it (#23139)", () => {
  const chip = pastedTextAttachment(LOG);
  expect(keptChips([chip])).toEqual([chip]);
  expect(chip).toMatchObject({ kind: "pasted", text: LOG, name: "line 1 of the build log" });
});

/// One Backspace press on the prompt, as the key delivers it (`repeat` while it is held down).
const backspace = (repeat = false) =>
  act(async () => {
    field().dispatchEvent(
      new dom.window.KeyboardEvent("keydown", { key: "Backspace", repeat, bubbles: true, cancelable: true }),
    );
  });

// Austin 2026-10-21: a pasted image could only go by its ×. Backspace at the prompt's start now
// takes back the last chip, as Claude's composer does; Backspace inside the text still edits it.
// That is the strip view's: there the chips are in the strip, and the text keeps their places hidden.
test("Backspace at the prompt's start removes the last chip, one per press; anywhere else it takes none", async () => {
  const composer = await openComposer();
  await showAttachments("strip");
  await paste("", [new File(["a"], "a.txt", { type: "text/plain" })]);
  await paste("", [new File(["b"], "b.txt", { type: "text/plain" })]);
  expect(chips(composer).map((chip) => chip.name)).toEqual(["a.txt", "b.txt"]);
  await typeDraft("hi");
  // The caret is after "hi": the key is the editor's, and no chip goes.
  await backspace();
  expect(chips(composer).map((chip) => chip.name)).toEqual(["a.txt", "b.txt"]);
  await act(async () => markdownField().setCaret(0));
  await backspace();
  expect(chips(composer).map((chip) => chip.name)).toEqual(["a.txt"]);
  // Holding Backspace down to clear the prompt stops at its start: a repeat takes no chip.
  await backspace(true);
  expect(chips(composer).map((chip) => chip.name)).toEqual(["a.txt"]);
  await backspace();
  expect(chips(composer)).toEqual([]);
  expect(placed()).toEqual([]);
  expect(words()).toBe("hi");
});

test.each(["inline", "strip"] as const)(
  "Backspace at the start of a heading lifts the heading; the chips stay (%s view)",
  async (view) => {
    const composer = await openComposer();
    await showAttachments(view);
    await act(async () => markdownField().type("# Title"));
    // The file goes in at the caret, the heading's end: Backspace at its start takes no chip.
    await paste("", [new File(["a"], "a.txt", { type: "text/plain" })]);
    await act(async () => markdownField().setCaret(0));
    await backspace();
    expect(chips(composer).map((chip) => chip.name)).toEqual(["a.txt"]);
    expect(placed()).toEqual([chips(composer)[0]!.id]);
    expect(withoutInlineTokens(markdownField().value())).toBe("Title");
  },
);
