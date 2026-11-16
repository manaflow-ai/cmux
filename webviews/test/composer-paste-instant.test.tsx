// Leo 2026-10-21 (nightly 3a63d6d): "ME PASTING IT DOESN'T JUST PASTE RIGHT INTO THE COMPOSER
// IMMEDIATELY". A pasted screenshot showed no chip until the composer had read, scaled and
// re-encoded it (attachments.ts fitImage), which takes a large Retina screenshot hundreds of ms. A
// paste now puts a placeholder chip in the strip in the paste's own frame; the real chip takes its
// place once the file is read, and a prompt sent meanwhile goes once its chips are ready, with them.
import { afterAll, afterEach, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act, createRef, type ComponentProps } from "react";
import type { Root } from "react-dom/client";
import { noChat } from "../src/gallery/fixtures/acpmux";
import type { Composer as ComposerView, ComposerHandle } from "../src/agent-session/acpmux/Composer";
import type { ComposerAttachment } from "../src/agent-session/acpmux/attachments";
import type { KeptAttachments } from "../src/agent-session/acpmux/composer/keptAttachments";
import type { MarkdownFieldElement } from "../src/agent-session/acpmux/MarkdownField";
import {
  DEFAULT_COMPOSER,
  setComposerSettings,
  type AttachmentView,
} from "../src/agent-session/acpmux/composerSettings";
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
  "createImageBitmap",
  "OffscreenCanvas",
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
    ...imageEngine(),
  });
  host = window.document.getElementById("root")!;
});

afterEach(() => {
  act(() => root?.unmount());
  root = undefined;
  host.replaceChildren();
  showAttachments(DEFAULT_COMPOSER.attachmentView);
  // Each test's chat starts with no kept draft: an attachment brought is the person's edit, so the
  // prompt holding it is kept for the chat (Composer.tsx `place`).
  dom.window.localStorage.clear();
});

afterAll(async () => {
  await teardownDom(saved, { window: dom.window, scope });
});

function Chips() {
  return null;
}

// A PNG's signature and header, padded past a spacer image's size.
const PNG = Uint8Array.from([
  0x89,
  0x50,
  0x4e,
  0x47,
  0x0d,
  0x0a,
  0x1a,
  0x0a,
  0,
  0,
  0,
  0x0d,
  0x49,
  0x48,
  0x44,
  0x52,
  // Its size, 640x480 (the composer reads it before it decodes the picture), then filler.
  0,
  0,
  2,
  0x80,
  0,
  0,
  1,
  0xe0,
  ...Array(504).fill(7),
]);

/// The engine's image decoder and canvas, which jsdom lacks. Every attached image is decoded and
/// re-encoded to strip its metadata (composer/imageWork.ts prepareImage, since #24652); with no
/// engine to draw it is no image. This one reads the file's bytes as a real decode does, and each
/// canvas encodes back to the screenshot's own PNG.
function imageEngine() {
  return {
    createImageBitmap: async (source: Blob) => {
      await source.arrayBuffer();
      return { width: 640, height: 480, close() {} };
    },
    OffscreenCanvas: class {
      constructor(
        public width: number,
        public height: number,
      ) {}
      getContext() {
        return { drawImage() {}, fillRect() {}, fillStyle: "" };
      }
      async convertToBlob({ type }: { type: string }) {
        return new Blob([PNG], { type });
      }
    },
  };
}

/// A screenshot whose bytes come only when `release()` is called: a large image the composer is
/// still reading and scaling.
/// A screenshot whose read waits for `release`; each its own size, as two screenshots are (one of a
/// type and size is read for its twin first: attachments.ts filesOnce).
let slowScreenshots = 0;
function slowScreenshot() {
  let release!: () => void;
  const gate = new Promise<void>((resolve) => (release = resolve));
  class Slow extends File {
    override async arrayBuffer() {
      await gate;
      return super.arrayBuffer();
    }
  }
  return {
    file: new Slow([PNG, new Uint8Array(++slowScreenshots)], "image.png", { type: "image/png" }),
    release,
  };
}

/// Yields to React until `ready()` holds; fails after 2 s with what it waited for.
async function until(ready: () => boolean, what: string) {
  const deadline = performance.now() + 2_000;
  while (!ready()) {
    if (performance.now() > deadline) throw new Error(`timed out waiting for ${what}`);
    await act(async () => {
      await new Promise((resolve) => setTimeout(resolve, 0));
    });
  }
}

async function openComposer(
  sent: { text: string; attachments: ComposerAttachment[] }[] = [],
  sessionId = "chat-a",
  extra: Partial<ComponentProps<typeof ComposerView>> = {},
) {
  const { createRoot } = await import("react-dom/client");
  const { Composer } = await import("../src/agent-session/acpmux/Composer");
  const handle = createRef<ComposerHandle>();
  const snapshot = noChat([], {
    sessionId,
    summary: { sessionId, harness: "claude", cwd: "/Users/you/src/app", turnCount: 0 },
  });
  root ??= createRoot(host);
  await act(async () =>
    root!.render(
      <Composer
        snapshot={snapshot}
        sessionId={sessionId}
        chips={Chips}
        onSend={(text, attachments) => {
          sent.push({ text, attachments: attachments ?? [] });
          return true;
        }}
        onStop={() => {}}
        onProject={() => {}}
        onNewChat={() => {}}
        localName="studio"
        projectChoices={[{ cwd: "/Users/you/src/app", label: "app" }]}
        handle={handle}
        {...extra}
      />,
    ),
  );
  return handle;
}

const field = () => host.querySelector<HTMLElement>('[role="combobox"]')!;
/// Settings' attachment view: the default draws a paste's chip in the prompt where it went (at the
/// caret); the strip view draws it in the strip (inlineAttachments.tsx).
let view: AttachmentView = DEFAULT_COMPOSER.attachmentView;
const showAttachments = (next: AttachmentView) => {
  view = next;
  act(() => setComposerSettings({ attachmentView: next }));
};
/// The attachment chips the view draws: in the prompt, or in the strip.
const chips = () => [
  ...host.querySelectorAll<HTMLElement>(
    view === "inline" ? "[data-inline-attachment] .acpmux-md-inline-chip" : ".acpmux-attachments .acpmux-attachment",
  ),
];
const placeholders = () => chips().filter((chip) => chip.getAttribute("aria-busy") === "true");

/// Pastes `files` on the prompt field as WebKit delivers it, in one task: what the strip shows
/// when the event's own task ends (React flushes a paste's update before the next paint).
/// The task ends with its microtasks, still before the frame paints: the prompt's field tells the
/// composer of a placed chip's element in one (MarkdownField `tellInlineViews`). No macrotask runs,
/// so no read of a pasted file can finish.
async function paste(files: File[]) {
  const data = { files, types: ["Files"], getData: () => "" };
  const event = new dom.window.Event("paste", { bubbles: true, cancelable: true });
  Object.defineProperty(event, "clipboardData", { value: data });
  act(() => {
    field().dispatchEvent(event);
  });
  // As the page runs, not a test's act(): an update React only schedules does not draw in this task.
  scope.IS_REACT_ACT_ENVIRONMENT = false;
  try {
    for (let turn = 0; turn < 3; turn++) await new Promise<void>((resolve) => queueMicrotask(resolve));
  } finally {
    scope.IS_REACT_ACT_ENVIRONMENT = true;
  }
}

/// The host's kept chips (AgentPaneDraftAttachments.swift), in memory: what each chat holds.
function keptStore() {
  const chats = new Map<string, ComposerAttachment[]>();
  const store: KeptAttachments = {
    read: async (chat) => chats.get(chat) ?? [],
    write: async (chat, chips) => {
      chats.set(chat, chips);
      return { held: chips.map((chip) => chip.id) };
    },
  };
  return { chats, store };
}

test.each(["inline", "strip"] as const)(
  "a pasted screenshot shows a chip in the paste's own frame, before its bytes are read (%s view)",
  async (shown) => {
    const composer = await openComposer();
    showAttachments(shown);
    const shot = slowScreenshot();
    await paste([shot.file]);
    // Nothing is read yet, and the prompt (or the strip) already holds the image's chip.
    expect(composer.current!.wakeState().attachments ?? []).toEqual([]);
    expect(chips()).toHaveLength(1);
    expect(placeholders()).toHaveLength(1);
    if (shown === "strip") expect(placeholders()[0]!.classList.contains("acpmux-attachment-image")).toBe(true);
    else expect(placeholders()[0]!.dataset.state).toBe("loading");
    // Once read, the image's own chip takes the placeholder's place.
    shot.release();
    await until(() => (composer.current!.wakeState().attachments ?? []).length === 1, "the read chip");
    expect(placeholders()).toHaveLength(0);
    expect(chips()).toHaveLength(1);
    expect(composer.current!.wakeState().attachments![0]!.kind).toBe("image");
  },
);

test.each(["inline", "strip"] as const)(
  "two screenshots pasted at once show two chips at once (%s view)",
  async (shown) => {
    await openComposer();
    showAttachments(shown);
    const first = slowScreenshot();
    const second = slowScreenshot();
    await paste([first.file, second.file]);
    expect(placeholders()).toHaveLength(2);
    first.release();
    second.release();
    await until(() => placeholders().length === 0, "the read chips");
    expect(chips()).toHaveLength(2);
  },
);

test("a prompt sent while its screenshot is still being read goes once the chip is ready, with it", async () => {
  const sent: { text: string; attachments: ComposerAttachment[] }[] = [];
  const composer = await openComposer(sent);
  const shot = slowScreenshot();
  await paste([shot.file]);
  act(() => {
    composer.current!.send();
  });
  // Not without the image, and not twice.
  expect(sent).toHaveLength(0);
  shot.release();
  await until(() => sent.length > 0, "the held prompt");
  await act(async () => {
    await new Promise((resolve) => setTimeout(resolve, 0));
  });
  expect(sent).toHaveLength(1);
  expect(sent[0]!.attachments.map((chip) => chip.kind)).toEqual(["image"]);
  expect(placeholders()).toHaveLength(0);
});

test("a prompt held for its screenshot never goes to the chat the composer moved to", async () => {
  const sent: { text: string; attachments: ComposerAttachment[] }[] = [];
  const { chats, store } = keptStore();
  const composer = await openComposer(sent, "chat-a", { keptAttachments: store });
  const shot = slowScreenshot();
  await paste([shot.file]);
  act(() => {
    composer.current!.send();
  });
  await openComposer(sent, "chat-b", { keptAttachments: store });
  shot.release();
  // The read ends (its chip goes to chat-a) with the composer on chat-b.
  await until(() => (chats.get("chat-a") ?? []).length === 1, "the read chip");
  await act(async () => {
    await new Promise((resolve) => setTimeout(resolve, 0));
  });
  expect(sent).toHaveLength(0);
});

test("a screenshot still being read when the composer moves to another chat goes to the chat it was pasted in", async () => {
  const { chats, store } = keptStore();
  await openComposer([], "chat-a", { keptAttachments: store });
  const shot = slowScreenshot();
  await paste([shot.file]);
  expect(placeholders()).toHaveLength(1);
  const onB = await openComposer([], "chat-b", { keptAttachments: store });
  // Its placeholder stays with chat-a.
  expect(placeholders()).toHaveLength(0);
  shot.release();
  await until(() => (chats.get("chat-a") ?? []).length === 1, "chat-a keeping the read chip");
  expect(chats.get("chat-a")![0]!.kind).toBe("image");
  expect(onB.current!.wakeState().attachments ?? []).toEqual([]);
  expect(chips()).toHaveLength(0);
  // Back on chat-a, the chip is there.
  const onA = await openComposer([], "chat-a", { keptAttachments: store });
  await until(() => (onA.current!.wakeState().attachments ?? []).length === 1, "chat-a's chip back");
  expect(onA.current!.wakeState().attachments![0]!.kind).toBe("image");
});

test("⌘Return in the Quick Composer while a screenshot is being read sends it with the image, then opens the window", async () => {
  const sent: { text: string; attachments: ComposerAttachment[] }[] = [];
  const opened: boolean[] = [];
  await openComposer(sent, "chat-a", { onOpenInWindow: (didSend) => opened.push(didSend) });
  const shot = slowScreenshot();
  await paste([shot.file]);
  act(() => {
    field().dispatchEvent(
      new dom.window.KeyboardEvent("keydown", { key: "Enter", metaKey: true, bubbles: true, cancelable: true }),
    );
  });
  // It waits for the image: nothing is sent and the window does not open without it.
  expect(sent).toHaveLength(0);
  expect(opened).toEqual([]);
  shot.release();
  await until(() => opened.length > 0, "the window opening");
  await act(async () => {
    await new Promise((resolve) => setTimeout(resolve, 0));
  });
  expect(sent).toHaveLength(1);
  expect(sent[0]!.attachments.map((chip) => chip.kind)).toEqual(["image"]);
  expect(opened).toEqual([true]);
});

const markdownField = () => host.querySelector<MarkdownFieldElement>(".acpmux-md-field")!.acpmuxMarkdownField!;

// Leo, 2026-11-07: "sometimes when I paste it, it loads, but it loads in that, like, top area. Like,
// you know, you expect it to be right at my caret ... There's, like, a sort of placeholder loading
// thing that I think doesn't necessarily always follow where the caret, where the attachment would
// be expected to go ... I saw some sort of flicker when that happened with the composer". A paste in
// the middle of the text puts its loading placeholder at the caret, inline, in the paste's own frame,
// and the strip above the text never draws it, not for one render: the strip appearing and leaving
// grew and shrank the composer (the flicker).
test("a screenshot pasted mid-text loads at the caret, and the strip above never draws it", async () => {
  const composer = await openComposer();
  showAttachments("inline");
  await act(async () => composer.current!.restore("hello world", []));
  await until(() => field().textContent?.includes("hello world") === true, "the prompt");
  await act(async () => markdownField().setCaret("hello ".length));
  // Every render the paste makes, as it lands: a loading tile in the strip, for any of them, is the
  // placeholder drawn above the caret's line.
  const inStrip: string[] = [];
  const watch = new dom.window.MutationObserver(() => {
    if (host.querySelector(".acpmux-attachments .acpmux-attachment")) inStrip.push(host.innerHTML);
  });
  watch.observe(host, { childList: true, subtree: true, attributes: true });
  const shot = slowScreenshot();
  try {
    await paste([shot.file]);
    // The paste's own frame: the placeholder is in the text where the caret was.
    const paragraph = field().querySelector("p")!;
    const node = paragraph.querySelector<HTMLElement>("[data-inline-attachment]");
    expect(node).not.toBeNull();
    expect(node!.querySelector('.acpmux-md-inline-chip[aria-busy="true"]')).not.toBeNull();
    expect(node!.previousSibling?.textContent).toBe("hello ");
    expect(node!.nextSibling?.textContent).toBe("world");
    shot.release();
    await until(() => (composer.current!.wakeState().attachments ?? []).length === 1, "the read chip");
    await until(() => placeholders().length === 0, "the ready chip");
  } finally {
    watch.disconnect();
  }
  expect(inStrip).toHaveLength(0);
  expect(host.querySelector(".acpmux-attachments .acpmux-attachment")).toBeNull();
  const placed = markdownField().value();
  expect(placed.indexOf("hello")).toBeLessThan(placed.indexOf("\uFFFC"));
  expect(placed.indexOf("\uFFFC")).toBeLessThan(placed.indexOf("world"));
});

// The same over a selection: a screenshot pasted over a selection that crosses lines (or the whole
// prompt, Select All) takes the selection's place, its placeholder there in the paste's frame; it
// never waits in the strip above and jumps into the text once read.
test.each([
  [
    "a selection across two lines",
    "first line\n\nsecond line",
    (field: MarkdownFieldHandleLike) =>
      field.writeText("first line\nsecond line", "first ".length, "first line\nsecond".length),
  ],
  ["the whole prompt", "first line\n\nsecond line", (field: MarkdownFieldHandleLike) => field.selectAll()],
] as const)("a screenshot pasted over %s loads where the selection was", async (_what, draft, select) => {
  const composer = await openComposer();
  showAttachments("inline");
  await act(async () => composer.current!.restore(draft, []));
  await until(() => field().textContent?.includes("second line") === true, "the prompt");
  await act(async () => select(markdownField()));
  const inStrip: number[] = [];
  const watch = new dom.window.MutationObserver(() => {
    if (host.querySelector(".acpmux-attachments .acpmux-attachment")) inStrip.push(1);
  });
  watch.observe(host, { childList: true, subtree: true, attributes: true });
  const shot = slowScreenshot();
  try {
    await paste([shot.file]);
    expect(field().querySelector('[data-inline-attachment] .acpmux-md-inline-chip[aria-busy="true"]')).not.toBeNull();
    shot.release();
    await until(() => placeholders().length === 0 && chips().length === 1, "the ready chip");
  } finally {
    watch.disconnect();
  }
  expect(inStrip).toHaveLength(0);
});
type MarkdownFieldHandleLike = { writeText(value: string, start: number, end: number): void; selectAll(): void };

// Where a plain caret can sit at a line's edge: the end of the text, an empty line after it
// (Shift-Enter), and just after a line break inside a paragraph. The placeholder goes in there, in the
// paste's frame, never in the strip above and never at the text's start.
test.each([
  ["at the end of the text", "hello world", Number.MAX_SAFE_INTEGER, false],
  ["on an empty line after it", "hello world", Number.MAX_SAFE_INTEGER, true],
  ["just after a line break", "hello\nworld", "hello".length + 1, false],
] as const)("a screenshot pasted with the caret %s loads at the caret", async (where, draft, caret, newLine) => {
  const rects = { getClientRects: () => [], getBoundingClientRect: () => new dom.window.DOMRect() };
  Object.assign(dom.window.Range.prototype, rects);
  Object.assign(dom.window.Element.prototype, { getClientRects: () => [] });
  await openComposer([], `chat-${where.replaceAll(" ", "-")}`);
  showAttachments("inline");
  await until(
    () => Boolean(host.querySelector<MarkdownFieldElement>(".acpmux-md-field")?.acpmuxMarkdownField),
    "the field",
  );
  // Typed as plain lines: a line break inside one paragraph where the text has one.
  await act(async () => {
    markdownField().focus();
    markdownField().insertText(draft);
  });
  await until(() => field().textContent?.includes("world") === true, "the prompt");
  if (draft.includes("\n")) expect(field().querySelectorAll("p br:not(.ProseMirror-trailingBreak)").length).toBe(1);
  await act(async () => {
    markdownField().setCaret(caret);
  });
  if (newLine)
    act(() => {
      field().dispatchEvent(
        new dom.window.KeyboardEvent("keydown", {
          key: "Enter",
          code: "Enter",
          keyCode: 13,
          shiftKey: true,
          bubbles: true,
          cancelable: true,
        }),
      );
    });
  const inStrip: number[] = [];
  const watch = new dom.window.MutationObserver(() => {
    if (host.querySelector(".acpmux-attachments .acpmux-attachment")) inStrip.push(1);
  });
  watch.observe(host, { childList: true, subtree: true, attributes: true });
  const shot = slowScreenshot();
  try {
    await paste([shot.file]);
    expect(field().querySelector('[data-inline-attachment] .acpmux-md-inline-chip[aria-busy="true"]')).not.toBeNull();
    shot.release();
    await until(() => placeholders().length === 0 && chips().length === 1, "the ready chip");
  } finally {
    watch.disconnect();
  }
  expect(inStrip).toHaveLength(0);
  const placed = markdownField().value();
  // After "hello" and its break or line: never at the text's start.
  expect(placed.indexOf("\uFFFC")).toBeGreaterThan(placed.indexOf("hello"));
  if (caret === Number.MAX_SAFE_INTEGER) expect(placed.indexOf("\uFFFC")).toBeGreaterThan(placed.indexOf("world"));
  else expect(placed.indexOf("\uFFFC")).toBeLessThan(placed.indexOf("world"));
});

// Review of #37674 (F1): only the paste's own gesture takes the selection's place. A screenshot pasted
// with the caret in a code block cannot go there: it goes at the start of the prompt's first line that
// can hold it (never the strip above the text); the person then selects the whole prompt while it
// loads. Once read, it stays in that node, and that never deletes what is typed.
test("an attachment placed once read never replaces the selection the person made meanwhile", async () => {
  const rects = { getClientRects: () => [], getBoundingClientRect: () => new dom.window.DOMRect() };
  Object.assign(dom.window.Range.prototype, rects);
  Object.assign(dom.window.Element.prototype, { getClientRects: () => [] });
  const composer = await openComposer([], "chat-code-block");
  showAttachments("inline");
  await act(async () => composer.current!.restore("```\nlet x = 1\n```\n\nhello world", []));
  await until(() => field().textContent?.includes("hello world") === true, "the prompt");
  // The caret in the code block (the document's first block).
  await act(async () => {
    markdownField().focus();
    markdownField().setCaret(2);
  });
  const shot = slowScreenshot();
  await paste([shot.file]);
  // Not in the code block: at the start of the line after it.
  expect(field().querySelector("pre [data-inline-attachment]")).toBeNull();
  expect(field().querySelector("p [data-inline-attachment]")).not.toBeNull();
  await act(async () => markdownField().selectAll());
  shot.release();
  await until(() => (composer.current!.wakeState().attachments ?? []).length === 1, "the read chip");
  await act(async () => {
    await new Promise((resolve) => setTimeout(resolve, 0));
  });
  const value = markdownField().value();
  expect(value).toContain("let x = 1");
  expect(value).toContain("hello world");
  expect(markdownField().inlineIds()).toHaveLength(1);
});

// Review of #37674 (F2): a read under 400 ms shows no indicator at all, with or without animations
// (the host's animations-off setting zeroes every CSS delay, so the wait is the tile's own timer).
test("a loading tile's indicator waits 400 ms, by its own timer", async () => {
  await openComposer([], "chat-late-indicator");
  showAttachments("inline");
  const shot = slowScreenshot();
  await paste([shot.file]);
  const late = () => field().querySelector<HTMLElement>('[aria-busy="true"] .acpmux-paste-late');
  expect(late()).not.toBeNull();
  expect(late()!.hasAttribute("data-late")).toBe(false);
  expect(late()!.querySelector("svg")).toBeNull();
  await until(() => late()?.hasAttribute("data-late") === true, "the late indicator");
  expect(late()!.querySelector("svg")).not.toBeNull();
  shot.release();
  await until(() => placeholders().length === 0, "the ready chip");
});

// Leo, 2026-11-09: "have we fixed the attachments preview going into the top area of hte composer and
// THEN to where they shuld be yet too?" A chip the host makes for the chat (a long dictation recording
// it sends to the chat's machine, Composer.tsx `attachLater`) loads in the text at the caret, as a
// paste's does, and the chip it becomes takes that same place: the strip above the text never draws
// it, not while it loads, not when it fails, and not when Retry makes it again.
test("a recording the host makes for the chat loads at the caret and stays there through a failure and Retry", async () => {
  const composer = await openComposer();
  showAttachments("inline");
  await act(async () => composer.current!.restore("hello world", []));
  await until(() => field().textContent?.includes("hello world") === true, "the prompt");
  await act(async () => markdownField().setCaret("hello ".length));
  const inStrip: string[] = [];
  const watch = new dom.window.MutationObserver(() => {
    if (host.querySelector(".acpmux-attachments .acpmux-attachment")) inStrip.push(host.innerHTML);
  });
  watch.observe(host, { childList: true, subtree: true, attributes: true });
  const makes: ((made: ComposerAttachment | undefined) => void)[] = [];
  const recording: ComposerAttachment = {
    id: "made-by-host",
    kind: "audio",
    name: "Recording.wav",
    mimeType: "audio/wav",
    size: 4,
    path: "/remote/Recording.wav",
  };
  const node = () => field().querySelector<HTMLElement>("p [data-inline-attachment]");
  try {
    act(() =>
      composer.current!.attachLater(
        "Recording.wav",
        () => new Promise((resolve) => makes.push(resolve)),
        "could not send",
      ),
    );
    await until(() => node()?.querySelector('[aria-busy="true"]') != null, "the loading tile in the text");
    expect(node()!.previousSibling?.textContent).toBe("hello ");
    expect(node()!.nextSibling?.textContent).toBe("world");
    const id = node()!.getAttribute("data-inline-attachment");
    // It fails: the tile says so where it is, with Retry.
    await act(async () => makes[0]!(undefined));
    await until(() => node()?.querySelector(".acpmux-md-inline-retry") != null, "Retry on the tile");
    act(() => node()!.querySelector<HTMLElement>(".acpmux-md-inline-retry")!.click());
    await until(() => makes.length === 2, "the second make");
    expect(node()!.getAttribute("data-inline-attachment")).toBe(id);
    // Made: the chip is the tile's, at the tile's place.
    await act(async () => makes[1]!(recording));
    await until(() => (composer.current!.wakeState().attachments ?? []).length === 1, "the made chip");
    await until(() => node()?.querySelector('[aria-busy="true"]') === null, "the made chip in the text");
    expect(node()!.getAttribute("data-inline-attachment")).toBe(id);
    expect(field().querySelectorAll("[data-inline-attachment]")).toHaveLength(1);
    expect(node()!.previousSibling?.textContent).toBe("hello ");
  } finally {
    watch.disconnect();
  }
  expect(inStrip).toHaveLength(0);
  expect(composer.current!.wakeState().attachments![0]!.path).toBe("/remote/Recording.wav");
});
