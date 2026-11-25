// The Messages compose bar's send rules (plans/cmux-next/home-mac.md): Send clears the field at once;
// a send the owner refuses before it is logged gives the text back; offline (H17) Send is off and the
// text stays a draft. And the whole transcript renders only the visible window of a 10,000-message
// chat.
import { afterEach, expect, test } from "bun:test";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import { settleReact } from "./support/domTeardown";

let dom: JSDOM | undefined;
let root: Root | undefined;
const scope = globalThis as Record<string, unknown>;
const saved = new Map<string, unknown>();

function installDom(): HTMLElement {
  dom = new JSDOM("<!doctype html><html><body><main id=root></main></body></html>", { pretendToBeVisual: true });
  Object.assign(dom.window, {
    ResizeObserver: class {
      observe() {}
      unobserve() {}
      disconnect() {}
    },
  });
  for (const key of [
    "window",
    "document",
    "navigator",
    "HTMLElement",
    "Element",
    "Node",
    "CSS",
    "MouseEvent",
    "KeyboardEvent",
    "getComputedStyle",
    "requestAnimationFrame",
    "cancelAnimationFrame",
    "ResizeObserver",
    "IS_REACT_ACT_ENVIRONMENT",
  ])
    saved.set(key, scope[key]);
  Object.assign(scope, {
    window: dom.window,
    document: dom.window.document,
    navigator: dom.window.navigator,
    HTMLElement: dom.window.HTMLElement,
    Element: dom.window.Element,
    Node: dom.window.Node,
    CSS: { escape: (value: string) => value },
    MouseEvent: dom.window.MouseEvent,
    KeyboardEvent: dom.window.KeyboardEvent,
    getComputedStyle: dom.window.getComputedStyle.bind(dom.window),
    requestAnimationFrame: (run: (time: number) => void) => setTimeout(() => run(0), 0),
    cancelAnimationFrame: (id: number) => clearTimeout(id),
    ResizeObserver: (dom.window as unknown as { ResizeObserver: unknown }).ResizeObserver,
    IS_REACT_ACT_ENVIRONMENT: true,
  });
  return dom.window.document.getElementById("root")!;
}

afterEach(async () => {
  if (root) act(() => root!.unmount());
  root = undefined;
  await settleReact();
  dom?.window.close();
  dom = undefined;
  for (const [key, value] of saved) {
    if (value === undefined) delete scope[key];
    else scope[key] = value;
  }
  saved.clear();
});

const { MessageComposer } = await import("../src/pages/home-messages/transcript/MessageComposer");
const { MessagesTranscript } = await import("../src/pages/home-messages/transcript/MessagesTranscript");
const { createTranscriptStrings } = await import("../src/pages/home-messages/transcript/strings");
type HomeMessage = import("../src/pages/home-channels/types").HomeMessage;
type HomeConversation = import("../src/pages/home-channels/types").HomeConversation;

const strings = createTranscriptStrings(["en"]);
const sendButton = (container: HTMLElement) =>
  container.querySelector<HTMLButtonElement>(`button[aria-label="${strings.t("home.compose.send")}"]`);
const settle = () => act(async () => new Promise((resolve) => setTimeout(resolve, 0)));

async function renderComposer(container: HTMLElement, props: Partial<Parameters<typeof MessageComposer>[0]>) {
  await act(async () => {
    root = createRoot(container);
    root.render(<MessageComposer strings={strings} sendEnabled onSend={async () => true} {...props} />);
  });
  await settle();
}

test("Send clears the field at once and hands the text to the owner", async () => {
  const container = installDom();
  const sent: string[] = [];
  await renderComposer(container, {
    initialText: "hello",
    onSend: async (text) => {
      sent.push(text);
      return true;
    },
  });
  expect(sendButton(container)?.disabled).toBe(false);
  await act(async () => sendButton(container)!.click());
  await settle();
  expect(sent).toEqual(["hello"]);
  // The field is empty: the Send button goes with the text.
  expect(sendButton(container)).toBeNull();
});

test("a send the owner refuses gives the text back with a notice", async () => {
  const container = installDom();
  await renderComposer(container, { initialText: "hello", onSend: async () => false });
  await act(async () => sendButton(container)!.click());
  await settle();
  expect(sendButton(container)).not.toBeNull();
  expect(container.querySelector('[role="alert"]')?.textContent).toBe(strings.t("home.send.refused.generic"));
});

test("a refused send gives its files back to the tray", async () => {
  const container = installDom();
  let handle: import("../src/pages/home-messages/transcript/MessageComposer").MessageComposerHandle | null = null;
  const sent: number[] = [];
  const service = {
    upload: async (_conversation: string, file: File) => ({
      type: "attachment" as const,
      hash: "h1",
      name: file.name,
      mimeType: "text/plain",
      byteCount: file.size,
    }),
  };
  await renderComposer(container, {
    attachments: { service: service as never, conversation: "c1" },
    ref: (value) => void (handle = value),
    onSend: async (_text, files) => {
      sent.push(files?.length ?? 0);
      return false;
    },
  });
  await act(async () => handle!.addFiles([new File(["notes"], "notes.txt", { type: "text/plain" })]));
  await settle();
  expect(container.querySelectorAll(".hc-tray-item.done")).toHaveLength(1);
  await act(async () => sendButton(container)!.click());
  await settle();
  expect(sent).toEqual([1]);
  // The owner refused it: the file is staged again, ready to send.
  expect(container.querySelectorAll(".hc-tray-item.done")).toHaveLength(1);
  expect(container.querySelector('[role="alert"]')?.textContent).toBe(strings.t("home.send.refused.generic"));
});

test("offline, Send is off and the draft stays", async () => {
  const container = installDom();
  const sent: string[] = [];
  await renderComposer(container, {
    initialText: "hello",
    sendEnabled: false,
    onSend: async (text) => {
      sent.push(text);
      return true;
    },
  });
  const button = sendButton(container)!;
  expect(button.disabled).toBe(true);
  await act(async () => button.click());
  await settle();
  expect(sent).toEqual([]);
  expect(sendButton(container)).not.toBeNull();
  expect(container.querySelector(".mt-compose")?.getAttribute("data-offline")).toBe("true");
});

test("a 10,000-message chat renders only the rows near the viewport", async () => {
  const container = installDom();
  const conversation: HomeConversation = {
    id: "c1",
    owner: "local",
    title: "Ana",
    kind: "direct",
    participants: [
      { id: "me", kind: "human", name: "Me", chief: false },
      { id: "ana", kind: "human", name: "Ana", chief: false },
    ],
    lastSeq: 10_000,
    rev: 1,
    updatedAt: 0,
    unread: 0,
    mentions: 0,
    muted: false,
    pinned: false,
  };
  const messages: HomeMessage[] = Array.from({ length: 10_000 }, (_, index) => ({
    id: `m${index}`,
    conversation: "c1",
    seq: index + 1,
    author: index % 2 ? "ana" : "me",
    createdAt: 1_700_000_000_000 + index * 30_000,
    retracted: false,
    parts: [{ type: "text", text: `message ${index}`, mentions: [] }],
    reactions: [],
  }));
  await act(async () => {
    root = createRoot(container);
    root.render(
      <MessagesTranscript
        strings={strings}
        me="me"
        conversation={conversation}
        messages={messages}
        connection="online"
        onSend={async () => true}
        onLoadOlder={() => {}}
        now={1_700_000_000_000 + 10_000 * 30_000}
      />,
    );
  });
  const rendered = container.querySelectorAll(".mt-slot").length;
  expect(rendered).toBeGreaterThan(0);
  expect(rendered).toBeLessThan(200);
});
