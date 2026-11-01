// Leo, 2026-10-28: "double paste of long block text should reveal it instead of duplicating the
// paste i think in the composer", then: "if you paste that and then paste again, then you don't
// have to click it. It just does it." A long block pasted into the composer is a Pasted text chip
// (composer-paste-text.test.tsx); the same block pasted again while that chip is held does what a
// click on the chip does: its text goes into the prompt, exactly as pasted, and the chip goes. It
// never makes a second chip of the same text (composer/pastedChips.ts).
import { afterAll, afterEach, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act, createRef, type RefObject } from "react";
import type { Root } from "react-dom/client";
import { noChat } from "../src/gallery/fixtures/acpmux";
import type { ComposerHandle } from "../src/agent-session/acpmux/Composer";
import { promptBlocks, withoutInlineTokens, type ComposerAttachment } from "../src/agent-session/acpmux/attachments";
import type { MarkdownFieldElement } from "../src/agent-session/acpmux/MarkdownField";

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
  // Every test opens chat "chat-a": its saved draft would come back in the next test's prompt.
  dom.window.localStorage.clear();
});

afterAll(async () => {
  // A frame the look dots asked for (StyleSwitch.tsx) can land after the last test's act: its render
  // runs in the next task, which must still have a window.
  await new Promise((resolve) => setTimeout(resolve, 0));
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

async function openComposer(sent: Sent[] = []) {
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
/// What the prompt sends as its own text.
/// The prompt's words: its text without the places of the chips held in it (inline, the default view).
const promptText = () => withoutInlineTokens(markdownField().agentText(markdownField().value()));

/// Pastes plain text on the prompt field as WebKit delivers it: one ClipboardEvent with its data.
async function paste(plain: string) {
  const data = {
    files: [],
    types: ["text/plain"],
    getData: (type: string) => (type === "text/plain" ? plain : ""),
  };
  const event = new dom.window.Event("paste", { bubbles: true, cancelable: true });
  Object.defineProperty(event, "clipboardData", { value: data });
  await act(async () => {
    field().dispatchEvent(event);
  });
  await settle();
}

/// 25 lines of a log (over the 20-line limit) with a blank line in it, which a paste keeps.
const LOG = Array.from({ length: 25 }, (_, index) => `line ${index + 1} of the build log`)
  .join("\n")
  .replace("line 13 of the build log\n", "line 13 of the build log\n\n");
const OTHER = Array.from({ length: 25 }, (_, index) => `row ${index + 1} of the other table`).join("\n");

const send = (composer: RefObject<ComposerHandle | null>) =>
  act(async () => {
    composer.current!.send();
  });

test("the same long block pasted again puts its chip's text in the prompt, as a click does; no second chip", async () => {
  const sent: Sent[] = [];
  const composer = await openComposer(sent);
  await paste(LOG);
  expect(chips(composer).map((chip) => chip.text)).toEqual([LOG]);
  expect(promptText()).toBe("");
  await paste(LOG);
  expect(chips(composer)).toEqual([]);
  expect(host.querySelector(".acpmux-attachment-pasted")).toBeNull();
  // Once, exactly as pasted (its blank line too): the text a click on the chip gives, not twice.
  expect(promptText()).toBe(LOG);
  await send(composer);
  expect(sent).toHaveLength(1);
  expect(sent[0]!.text).toBe(LOG);
  expect(sent[0]!.attachments).toEqual([]);
});

// Review (Codex): the paste that opens a held chip dropped the chip before its node left the
// prompt, so an undo brought back an empty node and the block was missing from the send. One undo
// brings the chip back with its text, as after a click on it.
test("undo after the same long block pasted again brings its chip back with its text", async () => {
  const sent: Sent[] = [];
  const composer = await openComposer(sent);
  await paste(LOG);
  const id = chips(composer)[0]!.id;
  await paste(LOG);
  expect(chips(composer)).toEqual([]);
  expect(promptText()).toBe(LOG);
  await act(async () => markdownField().undo());
  await settle();
  expect(chips(composer).map((chip) => [chip.id, chip.kind, chip.text])).toEqual([[id, "pasted", LOG]]);
  expect(promptText()).toBe("");
  await send(composer);
  expect(sent).toHaveLength(1);
  expect(sent[0]!.attachments.map((chip) => [chip.id, chip.text])).toEqual([[id, LOG]]);
});

test("the block pasted a third time, its chip already opened, is a chip again", async () => {
  const sent: Sent[] = [];
  const composer = await openComposer(sent);
  await paste(LOG);
  await paste(LOG);
  await paste(LOG);
  expect(chips(composer).map((chip) => chip.text)).toEqual([LOG]);
  expect(promptText()).toBe(LOG);
  // The prompt's text, then the chip's as its own block, each as pasted.
  await send(composer);
  expect(promptBlocks(sent[0]!.text, sent[0]!.attachments)).toEqual([
    { type: "text", text: LOG },
    { type: "text", text: LOG, _meta: { cmux: { pasted: true } } },
  ]);
});

test("a different long block pasted after one keeps both as chips, each sent as pasted", async () => {
  const sent: Sent[] = [];
  const composer = await openComposer(sent);
  await paste(LOG);
  await paste(OTHER);
  expect(chips(composer).map((chip) => chip.text)).toEqual([LOG, OTHER]);
  expect(promptText()).toBe("");
  await send(composer);
  expect(promptBlocks(sent[0]!.text, sent[0]!.attachments)).toEqual([
    { type: "text", text: LOG, _meta: { cmux: { pasted: true } } },
    { type: "text", text: OTHER, _meta: { cmux: { pasted: true } } },
  ]);
});

test("the first of two held blocks pasted again opens that chip only", async () => {
  const composer = await openComposer();
  await paste(LOG);
  await paste(OTHER);
  await paste(LOG);
  expect(chips(composer).map((chip) => chip.text)).toEqual([OTHER]);
  expect(promptText()).toBe(LOG);
});

test("a short paste twice stays text twice, no chip", async () => {
  const composer = await openComposer();
  await paste("short line");
  await paste("short line");
  expect(chips(composer)).toEqual([]);
  expect(promptText()).toBe("short lineshort line");
});

test("Paste as Plain Text of a block whose chip is held puts it in as text and keeps the chip", async () => {
  const composer = await openComposer();
  await paste(LOG);
  await act(async () => {
    field().dispatchEvent(
      new dom.window.KeyboardEvent("keydown", {
        key: "v",
        code: "KeyV",
        metaKey: true,
        shiftKey: true,
        bubbles: true,
        cancelable: true,
      }),
    );
  });
  await paste(LOG);
  expect(chips(composer).map((chip) => chip.text)).toEqual([LOG]);
  expect(promptText()).toBe(LOG);
});
