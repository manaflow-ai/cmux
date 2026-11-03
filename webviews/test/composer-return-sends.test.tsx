// Return sends from the composer; only Shift-Return adds a line (Leo 2026-10-21: "I pressed Enter
// and it only did a new line. That's not supposed to happen.", the agent working with three
// prompts queued). macOS Dictation, like an input method, passes Return on as keyCode 229 with
// key "Enter". The composer leaves every 229 key to the input method, but ProseMirror's own keymap
// read that key as Enter and split the paragraph, so no paragraph input ever reached the
// composer's Return path (#22741 caught only that input). A Return that commits an IME candidate
// belongs to the input method: it neither sends nor adds a line. An open command menu takes
// Return to pick; once Esc closes it, Return sends what is typed.
import { afterAll, afterEach, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act } from "react";
import type { Root } from "react-dom/client";
import { noChat, user } from "../src/gallery/fixtures/acpmux";
import type { AcpmuxSnapshot } from "../src/agent-session/acpmux/model";
import type { ComposerHandle } from "../src/agent-session/acpmux/Composer";
import { cmuxCommandRefusal, type CmuxCommand, type CmuxCommandResult } from "../src/agent-session/acpmux/cmuxCommands";
import { translate } from "../src/agent-session/acpmux/i18n";

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
  "createImageBitmap",
  "OffscreenCanvas",
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
  });
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

function Chips() {
  return null;
}

type Sent = { text: string; steer?: boolean };

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

/** A file still being read: its loading tile at its place in the prompt (inline, the default view). */
const LOADING = '.acpmux-md-inline-chip[data-state="loading"]';

/** Renders the composer over `snapshot`, types `typed` into it and returns its field and sends. */
async function composer(
  snapshot: AcpmuxSnapshot,
  typed: string,
  onCmuxCommand?: (command: CmuxCommand, args?: string) => CmuxCommandResult,
  importSandboxed = false,
  onImportFile?: (file: File) => void | Promise<void>,
  upload?: (files: File[]) => Promise<{ paths: string[] }>,
  onOpenInWindow?: (sent: boolean) => void,
) {
  const sent: Sent[] = [];
  const sentAttachments: string[][] = [];
  let handle: ComposerHandle | null = null;
  const { createRoot } = await import("react-dom/client");
  const { Composer } = await import("../src/agent-session/acpmux/Composer");
  root ??= createRoot(host);
  await act(async () =>
    root!.render(
      <Composer
        handle={(value) => void (handle = value)}
        snapshot={snapshot}
        sessionId={snapshot.sessionId ?? snapshot.summary?.sessionId}
        chips={Chips}
        onSend={(text, _attachments, steer) => {
          sent.push({ text, steer });
          sentAttachments.push((_attachments ?? []).map((attachment) => attachment.name));
          return true;
        }}
        onStop={() => {}}
        onProject={() => {}}
        onNewChat={() => {}}
        {...(onCmuxCommand ? { onCmuxCommand } : {})}
        {...(importSandboxed ? { importSandboxed } : {})}
        {...(onImportFile ? { onImportFile } : {})}
        {...(upload ? { upload } : {})}
        {...(onOpenInWindow ? { onOpenInWindow } : {})}
        localName="studio"
        projectChoices={[{ cwd: "/Users/you/src/app", label: "app" }]}
      />,
    ),
  );
  await act(async () => handle!.restore(typed, []));
  const field = host.querySelector<HTMLElement>("[role=combobox]")!;
  return {
    field,
    sent,
    sentAttachments,
    restore: (text: string) => act(async () => handle!.restore(text, [])),
  };
}

// Each test is its own chat, so no draft kept for one chat comes back in the next test.
let chats = 0;

function chat(fields: Partial<AcpmuxSnapshot> = {}): AcpmuxSnapshot {
  const sessionId = `chat-${++chats}`;
  return noChat([], {
    sessionId,
    summary: { sessionId, harness: "claude", cwd: "/Users/you/src/app", turnCount: 1 },
    rows: [user("Add retries", 1)],
    ...fields,
  });
}

/** Leo's chat: the agent working, steering, with three prompts queued. */
function working(): AcpmuxSnapshot {
  const snapshot = chat({
    isWorking: true,
    queue: [
      { id: "q1", prompt: "one" },
      { id: "q2", prompt: "two" },
      { id: "q3", prompt: "three" },
    ],
  });
  return { ...snapshot, summary: { ...snapshot.summary!, steering: true } };
}

/** Dispatches `event` on `field` at `timeStamp` (ms), inside act; returns whether its default ran. */
async function dispatch(field: HTMLElement, event: Event, timeStamp?: number): Promise<boolean> {
  if (timeStamp !== undefined) Object.defineProperty(event, "timeStamp", { value: timeStamp });
  let proceeded = true;
  await act(async () => {
    proceeded = field.dispatchEvent(event);
  });
  return proceeded;
}

const key = (init: KeyboardEventInit & { keyCode?: number }) =>
  new window.KeyboardEvent("keydown", { bubbles: true, cancelable: true, ...init });

/** The lines the field shows: its paragraphs, and the line breaks inside them. */
const lines = (field: HTMLElement) =>
  field.querySelectorAll("p").length + field.querySelectorAll("br:not(.ProseMirror-trailingBreak)").length;

test("Return sends what is typed", async () => {
  const { field, sent } = await composer(chat(), "What is Spotlight?");
  const proceeded = await dispatch(field, key({ key: "Enter", keyCode: 13 }));
  expect({ sent, proceeded }).toEqual({ sent: [{ text: "What is Spotlight?", steer: false }], proceeded: false });
});

const refuseCommand = (command: CmuxCommand, args?: string) => {
  const reason = cmuxCommandRefusal(command, args, {
    summary: true,
    forkable: false,
    sideAvailable: false,
    canContinue: false,
    sideSessions: false,
    session: true,
    isSideSession: false,
    targets: [{ id: "codex", name: "Codex" }],
  });
  return reason ? translate(reason) : true;
};

test("a refused cmux-owned command keeps its draft and shows the inline reason", async () => {
  const snapshot = chat({ commands: [], isWorking: true });
  const { field, sent } = await composer(snapshot, "/fork", refuseCommand);
  await dispatch(field, key({ key: "Enter", keyCode: 13 }));
  expect(sent).toEqual([]);
  expect(field.textContent).toContain("/fork");
  expect(host.querySelector(".acpmux-attachment-note")?.textContent).toContain("Fork is unavailable");
});

test("a cmux-owned command with an invalid target keeps its draft and explains the refusal", async () => {
  const snapshot = chat({ commands: [] });
  const { field, sent } = await composer(snapshot, "/continue nope", refuseCommand);
  await dispatch(field, key({ key: "Enter", keyCode: 13 }));
  expect(sent).toEqual([]);
  expect(field.textContent).toContain("/continue nope");
  expect(host.querySelector(".acpmux-attachment-note")?.textContent).toContain("No matching harness");
});

test("an unavailable side command keeps its draft and shows a side-specific refusal", async () => {
  const { field, sent } = await composer(chat({ commands: [] }), "/side", refuseCommand);
  await dispatch(field, key({ key: "Enter", keyCode: 13 }));
  expect(sent).toEqual([]);
  expect(field.textContent).toContain("/side");
  expect(host.querySelector(".acpmux-attachment-note")?.textContent).toContain("Use /side without arguments");
});

test("a synchronous import exception is visible in the existing chat composer", async () => {
  const { sent } = await composer(chat(), "/import", undefined, false, () => {
    throw new Error("Transcript could not be read");
  });
  const input = host.querySelector<HTMLInputElement>('input[aria-label="/import"]')!;
  Object.defineProperty(input, "files", { configurable: true, value: [new File(["{}"], "transcript.json")] });
  await act(async () => input.dispatchEvent(new window.Event("change", { bubbles: true })));
  expect(host.querySelector(".acpmux-attachment-note")?.textContent).toContain("Transcript could not be read");
  expect(sent).toEqual([]);
});

test("a Sandboxed chat refuses /import before the picker and ignores a late file", async () => {
  const imported: File[] = [];
  const { field, sent } = await composer(chat(), "/import", undefined, true, async (file) => {
    imported.push(file);
  });
  const input = host.querySelector<HTMLInputElement>('input[aria-label="/import"]')!;
  let opened = false;
  input.click = () => {
    opened = true;
  };
  await dispatch(field, key({ key: "Enter", keyCode: 13 }));
  expect(opened).toBe(false);
  expect(field.textContent).toContain("/import");
  expect(host.querySelector(".acpmux-attachment-note")?.textContent).toContain(
    "Transcript import is unavailable in Sandboxed mode",
  );

  Object.defineProperty(input, "files", { configurable: true, value: [new File(["{}"], "transcript.json")] });
  await act(async () => input.dispatchEvent(new window.Event("change", { bubbles: true })));
  expect(imported).toEqual([]);
  expect(sent).toEqual([]);
});

test("active-chat /import opens synchronously despite a pending file and consumes that read", async () => {
  let resolve!: (result: { paths: string[] }) => void;
  const page = await composer(
    chat(),
    "/import",
    undefined,
    false,
    async () => {},
    () =>
      new Promise((done) => {
        resolve = done;
      }),
  );
  const file = new File(["contents"], "pending.txt", { type: "text/plain" });
  const paste = new window.Event("paste", { bubbles: true, cancelable: true });
  Object.defineProperty(paste, "clipboardData", {
    value: { files: [file], types: ["Files"], getData: () => "" },
  });
  await act(async () => page.field.dispatchEvent(paste));
  expect(host.querySelector(LOADING)).not.toBeNull();
  let opened = false;
  host.querySelector<HTMLInputElement>('input[aria-label="/import"]')!.click = () => {
    opened = true;
  };
  await act(async () => {
    page.field.dispatchEvent(key({ key: "Enter", keyCode: 13 }));
    expect(opened).toBe(true);
  });
  expect(page.field.textContent).toBe("");
  expect(host.querySelector(LOADING)).toBeNull();
  expect(page.sent).toEqual([]);
  await act(async () => resolve({ paths: ["/tmp/pending.txt"] }));
  // Type into the field itself: restore() would replace attachments and hide a leaked pending read.
  await act(async () => {
    page.field.textContent = "Explain this file";
    page.field.dispatchEvent(new window.InputEvent("input", { bubbles: true, inputType: "insertText" }));
  });
  await dispatch(page.field, key({ key: "Enter", keyCode: 13 }));
  expect(page.sentAttachments).toEqual([[]]);
});

test("an attachment-only Return waits for a pending image and sends it when ready", async () => {
  const page = await composer(chat(), "");
  const file = new File([PNG], "pending.png", { type: "image/png" });
  const bytes = await file.arrayBuffer();
  let resolve!: (bytes: ArrayBuffer) => void;
  Object.defineProperty(file, "arrayBuffer", {
    value: () =>
      new Promise<ArrayBuffer>((done) => {
        resolve = done;
      }),
  });
  const paste = new window.Event("paste", { bubbles: true, cancelable: true });
  Object.defineProperty(paste, "clipboardData", {
    value: { files: [file], types: ["Files"], getData: () => "" },
  });
  await act(async () => page.field.dispatchEvent(paste));
  expect(host.querySelector(LOADING)).not.toBeNull();
  expect(page.field.textContent).toBe("");
  await dispatch(page.field, key({ key: "Enter", keyCode: 13 }));
  expect(page.sent).toEqual([]);
  await act(async () => resolve(bytes));
  // No words: the text is the image's place alone, its token (inlineToken, attachments.ts), where
  // the default inline view put it.
  expect(page.sent).toHaveLength(1);
  expect(page.sent[0]!.steer).toBe(false);
  expect(page.sent[0]!.text).toMatch(/^\uFFFC[^\uFFFC]+\uFFFC$/);
  expect(page.sentAttachments).toEqual([["pending.png"]]);
});

test("a terminal-only spelling waits for its pending image and sends as an attachment prompt", async () => {
  const page = await composer(chat(), "/logout");
  const file = new File([PNG], "pending.png", { type: "image/png" });
  const bytes = await file.arrayBuffer();
  let resolve!: (bytes: ArrayBuffer) => void;
  Object.defineProperty(file, "arrayBuffer", {
    value: () =>
      new Promise<ArrayBuffer>((done) => {
        resolve = done;
      }),
  });
  const paste = new window.Event("paste", { bubbles: true, cancelable: true });
  Object.defineProperty(paste, "clipboardData", {
    value: { files: [file], types: ["Files"], getData: () => "" },
  });
  await act(async () => page.field.dispatchEvent(paste));
  expect(host.querySelector(LOADING)).not.toBeNull();
  await dispatch(page.field, key({ key: "Enter", keyCode: 13 }));
  expect(page.sent).toEqual([]);
  expect(host.querySelector(".acpmux-attachment-note")).toBeNull();
  await act(async () => resolve(bytes));
  expect(page.sent).toEqual([{ text: "/logout", steer: false }]);
  expect(page.sentAttachments).toEqual([["pending.png"]]);
});

test("Quick Chat Cmd-Return opens /import immediately despite an earlier pending image", async () => {
  let opened = 0;
  const page = await composer(
    chat(),
    "/import",
    undefined,
    false,
    async () => {},
    undefined,
    () => {
      opened += 1;
    },
  );
  const file = new File([PNG], "pending.png", { type: "image/png" });
  const bytes = await file.arrayBuffer();
  let resolve!: (bytes: ArrayBuffer) => void;
  Object.defineProperty(file, "arrayBuffer", {
    value: () =>
      new Promise<ArrayBuffer>((done) => {
        resolve = done;
      }),
  });
  const paste = new window.Event("paste", { bubbles: true, cancelable: true });
  Object.defineProperty(paste, "clipboardData", {
    value: { files: [file], types: ["Files"], getData: () => "" },
  });
  await act(async () => page.field.dispatchEvent(paste));
  await dispatch(page.field, key({ key: "Enter", keyCode: 13, metaKey: true }));
  expect(opened).toBe(1);
  expect(host.querySelector(".acpmux-import-input")).not.toBeNull();
  await act(async () => resolve(bytes));
});

test("/btw keeps a file still being read for the main turn", async () => {
  let asked = 0;
  const page = await composer(chat(), "/btw question", () => {
    asked += 1;
    return true;
  });
  const file = new File([PNG], "pending.png", { type: "image/png" });
  const bytes = await file.arrayBuffer();
  let resolve!: (bytes: ArrayBuffer) => void;
  Object.defineProperty(file, "arrayBuffer", {
    value: () =>
      new Promise<ArrayBuffer>((done) => {
        resolve = done;
      }),
  });
  const paste = new window.Event("paste", { bubbles: true, cancelable: true });
  Object.defineProperty(paste, "clipboardData", {
    value: { files: [file], types: ["Files"], getData: () => "" },
  });
  await act(async () => page.field.dispatchEvent(paste));
  await dispatch(page.field, key({ key: "Enter", keyCode: 13 }));
  expect(asked).toBe(0);
  expect(page.field.textContent).toBe("/btw question");
  await act(async () => resolve(bytes));
  expect(host.querySelector(".acpmux-attachment-image")).not.toBeNull();
  expect(page.sent).toEqual([]);
});

for (const outcome of ["resolve", "reject", "edited"] as const) {
  test(`an asynchronous owned command consumes files but preserves its draft until ${outcome}`, async () => {
    let settle!: () => void;
    const accepted = new Promise<void>((resolve, reject) => {
      settle = outcome === "reject" ? () => reject(new Error("refused")) : resolve;
    });
    const page = await composer(chat(), "/continue codex", () => accepted);
    const paste = new window.Event("paste", { bubbles: true, cancelable: true });
    Object.defineProperty(paste, "clipboardData", {
      value: { files: [new File([PNG], "staged.png", { type: "image/png" })], types: ["Files"], getData: () => "" },
    });
    await act(async () => page.field.dispatchEvent(paste));
    expect(host.querySelector(".acpmux-attachment-image")).not.toBeNull();
    await dispatch(page.field, key({ key: "Enter", keyCode: 13 }));
    expect(page.field.textContent).toBe("/continue codex");
    expect(host.querySelector(".acpmux-attachment-image")).toBeNull();
    if (outcome === "edited") {
      await act(async () => {
        page.field.textContent = "A later edit";
        page.field.dispatchEvent(new window.InputEvent("input", { bubbles: true, inputType: "insertText" }));
      });
    }
    await act(async () => settle());
    expect(page.field.textContent).toBe(
      outcome === "edited" ? "A later edit" : outcome === "reject" ? "/continue codex" : "",
    );
    if (outcome === "reject") expect(host.querySelector(".acpmux-attachment-note")).not.toBeNull();
    expect(page.sent).toEqual([]);
  });
}

// Review of #26545 at 02c58d02: the command cancels a file still being read, and its loading node
// then leaves the text. That is no edit of the person's: the command's success still clears the draft.
test("an asynchronous owned command with a file still being read clears its draft when it succeeds", async () => {
  let settle!: () => void;
  const accepted = new Promise<void>((resolve) => {
    settle = resolve;
  });
  const page = await composer(chat(), "/continue codex", () => accepted);
  const file = new File([PNG], "pending.png", { type: "image/png" });
  Object.defineProperty(file, "arrayBuffer", { value: () => new Promise<ArrayBuffer>(() => {}) });
  const paste = new window.Event("paste", { bubbles: true, cancelable: true });
  Object.defineProperty(paste, "clipboardData", {
    value: { files: [file], types: ["Files"], getData: () => "" },
  });
  await act(async () => page.field.dispatchEvent(paste));
  expect(host.querySelector(LOADING)).not.toBeNull();
  await dispatch(page.field, key({ key: "Enter", keyCode: 13 }));
  // The loading node goes once its read is cancelled.
  for (let turn = 0; turn < 5 && host.querySelector(LOADING); turn += 1)
    await act(async () => new Promise((resolve) => setTimeout(resolve, 0)));
  expect(host.querySelector(LOADING)).toBeNull();
  await act(async () => settle());
  expect(page.field.textContent).toBe("");
  expect(page.sent).toEqual([]);
});

test("Return after Dictation (keyCode 229, no composition) steers the running turn, never adds a line", async () => {
  const { field, sent } = await composer(working(), "What is Spotlight?");
  // Dictation's text came in and its composition ended a while ago; then Return.
  await dispatch(field, new window.CompositionEvent("compositionstart", { bubbles: true }), 1_000);
  await dispatch(field, new window.CompositionEvent("compositionend", { bubbles: true }), 2_000);
  const proceeded = await dispatch(field, key({ key: "Enter", keyCode: 229 }), 6_000);
  expect({ sent, proceeded, lines: lines(field) }).toEqual({
    sent: [{ text: "What is Spotlight?", steer: true }],
    proceeded: false,
    lines: 1,
  });
});

test("Return the input method passes on with no composition at all sends", async () => {
  const { field, sent } = await composer(chat(), "Run the tests");
  const proceeded = await dispatch(field, key({ key: "Enter", keyCode: 229 }), 6_000);
  // Sent, the field is one empty line again; ProseMirror's keymap had split it into two.
  expect({ sent, proceeded, lines: lines(field) }).toEqual({
    sent: [{ text: "Run the tests", steer: false }],
    proceeded: false,
    lines: 1,
  });
});

test("the Return that commits an input method's candidate is the input method's: no send, no line", async () => {
  const { field, sent } = await composer(chat(), "日本語");
  await dispatch(field, new window.CompositionEvent("compositionstart", { bubbles: true }), 1_000);
  // During composition the committing Return is the input method's.
  const during = await dispatch(field, key({ key: "Enter", keyCode: 229, isComposing: true }), 1_500);
  // WebKit sends the committing Return just after compositionend, isComposing false.
  await dispatch(field, new window.CompositionEvent("compositionend", { bubbles: true }), 2_000);
  const after = await dispatch(field, key({ key: "Enter", keyCode: 229 }), 2_010);
  expect({ sent, during, after, lines: lines(field) }).toEqual({ sent: [], during: true, after: true, lines: 1 });
});

// WebKit (jsdom's vendor is Apple): ProseMirror's after-composition guard swallows the commit
// Return and clears itself. Kept from that keydown, the guard stayed armed, so a Shift-Return right
// after went to the browser, whose paragraph input sent the draft.
test("Shift-Return right after an input method's commit Return adds a line and sends nothing", async () => {
  const { field, sent } = await composer(chat(), "日本語");
  await dispatch(field, new window.CompositionEvent("compositionstart", { bubbles: true }), 1_000);
  await dispatch(field, new window.CompositionEvent("compositionend", { bubbles: true }), 2_000);
  await dispatch(field, key({ key: "Enter", keyCode: 229 }), 2_010);
  await dispatch(field, new window.KeyboardEvent("keyup", { key: "Enter", bubbles: true }), 2_050);
  const shift = key({ key: "Enter", keyCode: 13, shiftKey: true });
  const proceeded = await dispatch(field, shift, 2_300);
  if (proceeded)
    await dispatch(
      field,
      new window.InputEvent("beforeinput", { inputType: "insertParagraph", bubbles: true, cancelable: true }),
      2_301,
    );
  expect({ sent, lines: lines(field) }).toEqual({ sent: [], lines: 2 });
});

test("a paragraph the input method inserts on its own sends instead", async () => {
  const { field, sent } = await composer(working(), "What is Spotlight?");
  const inserted = await dispatch(
    field,
    new window.InputEvent("beforeinput", { inputType: "insertParagraph", bubbles: true, cancelable: true }),
  );
  expect({ sent, inserted }).toEqual({ sent: [{ text: "What is Spotlight?", steer: true }], inserted: false });
});

test("Return with the command menu closed sends the typed /word", async () => {
  const { field, sent } = await composer(chat({ commands: [{ name: "review", description: "Review" }] }), "/rev");
  expect(host.querySelector("#acpmux-slash-menu")).not.toBeNull();
  await dispatch(field, key({ key: "Escape" }));
  expect(host.querySelector("#acpmux-slash-menu")).toBeNull();
  const proceeded = await dispatch(field, key({ key: "Enter", keyCode: 13 }));
  expect({ sent, proceeded }).toEqual({ sent: [{ text: "/rev", steer: false }], proceeded: false });
});

test("Shift-Return adds a line and sends nothing", async () => {
  const { field, sent } = await composer(chat(), "first line");
  expect(lines(field)).toBe(1);
  await dispatch(field, key({ key: "Enter", keyCode: 13, shiftKey: true }));
  expect({ sent, lines: lines(field) }).toEqual({ sent: [], lines: 2 });
});
