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
import { promptBlocks, type ComposerAttachment } from "../src/agent-session/acpmux/attachments";
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
        localName="studio"
        projectChoices={[{ cwd: "/Users/you/src/app", label: "app" }]}
        handle={handle}
      />,
    ),
  );
  // The editor is made asynchronously; its element takes the combobox role once it is.
  for (let tries = 0; tries < 100 && !host.querySelector('[role="combobox"]'); tries += 1)
    await act(async () => {
      await new Promise((resolve) => setTimeout(resolve, 10));
    });
  return handle;
}

const field = () => host.querySelector<HTMLElement>('[role="combobox"]')!;
const markdownField = () => host.querySelector<MarkdownFieldElement>(".acpmux-md-field")!.acpmuxMarkdownField!;
const chips = (handle: RefObject<ComposerHandle | null>) => handle.current!.wakeState().attachments ?? [];

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
  await act(async () => {
    await new Promise((resolve) => setTimeout(resolve, 20));
  });
}

async function typeDraft(text: string) {
  await act(async () => {
    markdownField().focus();
    markdownField().insertTyped(text);
  });
}

/// 25 lines of a log: over the 20-line limit, under 2,000 characters.
const LOG = Array.from({ length: 25 }, (_, index) => `line ${index + 1} of the build log`).join("\n");

test("a paste over 20 lines is a Pasted text chip; the prompt keeps what was typed", async () => {
  const composer = await openComposer();
  await typeDraft("why does this fail?");
  await paste(LOG);
  const held = chips(composer);
  expect(held.map((chip) => chip.kind)).toEqual(["pasted"]);
  expect(held[0]!.text).toBe(LOG);
  expect(field().textContent).toBe("why does this fail?");
  const chip = host.querySelector(".acpmux-attachment-pasted")!;
  expect(chip).not.toBeNull();
  expect(chip.textContent).toContain("line 1 of the build log");
  expect(chip.textContent).toContain("25 lines");
});

test("a paste over 2,000 characters on one line is a chip too", async () => {
  const composer = await openComposer();
  const long = "word ".repeat(450);
  await paste(long);
  expect(chips(composer).map((chip) => chip.kind)).toEqual(["pasted"]);
  expect(field().textContent).toBe("");
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

test("× removes the chip and puts nothing in the prompt", async () => {
  const composer = await openComposer();
  await paste(LOG);
  const remove = host.querySelector<HTMLButtonElement>(".acpmux-attachment-pasted .acpmux-attachment-remove")!;
  expect(remove).not.toBeNull();
  await act(async () => remove.click());
  expect(chips(composer)).toEqual([]);
  expect(host.querySelector(".acpmux-attachment-pasted")).toBeNull();
  expect(field().textContent).toBe("");
});

test("a click on the chip puts its text back in the prompt to edit, and the chip goes", async () => {
  const composer = await openComposer();
  await paste(LOG);
  const open = host.querySelector<HTMLButtonElement>(".acpmux-attachment-pasted-open")!;
  expect(open).not.toBeNull();
  await act(async () => open.click());
  expect(chips(composer)).toEqual([]);
  expect(field().textContent).toContain("line 1 of the build log");
  expect(field().textContent).toContain("line 25 of the build log");
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
  expect(sent[0]!.text).toBe("why does this fail?");
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
