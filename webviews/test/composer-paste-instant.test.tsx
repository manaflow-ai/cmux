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
import { installComposerImageEngine } from "./support/composerImageEngine";

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
let restoreImageEngine: () => void;

beforeAll(() => {
  restoreImageEngine = installComposerImageEngine();
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
  restoreImageEngine();
  dom.window.close();
  for (const [key, had, value] of saved) {
    if (had) scope[key] = value;
    else delete scope[key];
  }
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

/// A screenshot whose bytes come only when `release()` is called: a large image the composer is
/// still reading and scaling.
function slowScreenshot() {
  let release!: () => void;
  const gate = new Promise<void>((resolve) => (release = resolve));
  class Slow extends File {
    override async arrayBuffer() {
      await gate;
      return super.arrayBuffer();
    }
  }
  return { file: new Slow([PNG], "image.png", { type: "image/png" }), release };
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
const chips = () => [...host.querySelectorAll<HTMLElement>(".acpmux-attachments .acpmux-attachment")];
const placeholders = () => chips().filter((chip) => chip.getAttribute("aria-busy") === "true");

/// Pastes `files` on the prompt field as WebKit delivers it, in one task: what the strip shows
/// when the event's own task ends (React flushes a paste's update before the next paint).
function paste(files: File[]) {
  const data = { files, types: ["Files"], getData: () => "" };
  const event = new dom.window.Event("paste", { bubbles: true, cancelable: true });
  Object.defineProperty(event, "clipboardData", { value: data });
  act(() => {
    field().dispatchEvent(event);
  });
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

test("a pasted screenshot shows a chip in the paste's own frame, before its bytes are read", async () => {
  const composer = await openComposer();
  const shot = slowScreenshot();
  paste([shot.file]);
  // Nothing is read yet, and the strip already holds the image's chip.
  expect(composer.current!.wakeState().attachments ?? []).toEqual([]);
  expect(chips()).toHaveLength(1);
  expect(placeholders()).toHaveLength(1);
  expect(placeholders()[0]!.classList.contains("acpmux-attachment-image")).toBe(true);
  // Once read, the image's own chip takes the placeholder's place.
  shot.release();
  await until(() => (composer.current!.wakeState().attachments ?? []).length === 1, "the read chip");
  expect(placeholders()).toHaveLength(0);
  expect(chips()).toHaveLength(1);
  expect(composer.current!.wakeState().attachments![0]!.kind).toBe("image");
});

test("two screenshots pasted at once show two chips at once", async () => {
  await openComposer();
  const first = slowScreenshot();
  const second = slowScreenshot();
  paste([first.file, second.file]);
  expect(placeholders()).toHaveLength(2);
  first.release();
  second.release();
  await until(() => placeholders().length === 0, "the read chips");
  expect(chips()).toHaveLength(2);
});

test("a prompt sent while its screenshot is still being read goes once the chip is ready, with it", async () => {
  const sent: { text: string; attachments: ComposerAttachment[] }[] = [];
  const composer = await openComposer(sent);
  const shot = slowScreenshot();
  paste([shot.file]);
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
  paste([shot.file]);
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
  paste([shot.file]);
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
  paste([shot.file]);
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
