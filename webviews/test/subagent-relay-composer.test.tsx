// A subagent's pane ends in the chat's own Composer relayed to the subagent (Composer.tsx `relay`,
// App.tsx `subagentRelay`; Leo 2026-11-22: "the subagent their composer area needs to be good too
// tho... we should align things better"). Its draft is the subagent's (subagentDrafts.ts), never the
// chat's: it starts from the kept draft, keeps every change, and a send that failed comes back into
// it whole. Quote in Reply (App.tsx `quoteReply`) goes into the subagent's prompt through the relay's
// own handle, never held for the chat's composer (Leo, 2026-11-06, on a subagent: "I should be able
// to, like, copy the stuff that it did.").
import { afterAll, afterEach, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act, createRef, type RefObject } from "react";
import type { ComposerAttachment } from "../src/agent-session/acpmux/attachments";
import type { ComposerHandle, ComposerRelay } from "../src/agent-session/acpmux/Composer";
import { noChat } from "../src/gallery/fixtures/acpmux";
import type { Root } from "react-dom/client";
import { proseMirrorGlobals } from "../src/agent-session/acpmux/promptFieldTesting";
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
  "getSelection",
  "getComputedStyle",
  "requestAnimationFrame",
  "cancelAnimationFrame",
  "KeyboardEvent",
  "InputEvent",
  "FocusEvent",
  "MouseEvent",
  "Event",
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
    Element: window.Element,
    getComputedStyle: window.getComputedStyle.bind(window),
    requestAnimationFrame: (run: (time: number) => void) => setTimeout(() => run(0), 0),
    cancelAnimationFrame: (id: number) => clearTimeout(id),
    KeyboardEvent: window.KeyboardEvent,
    InputEvent: window.InputEvent,
    FocusEvent: window.FocusEvent,
    MouseEvent: window.MouseEvent,
    Event: window.Event,
    localStorage: window.localStorage,
    ...proseMirrorGlobals(window as unknown as Window & typeof globalThis),
  });
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

const settle = () => act(async () => new Promise((resolve) => setTimeout(resolve, 0)));
async function until(ready: () => boolean) {
  for (let turn = 0; turn < 200 && !ready(); turn++) await settle();
}

/** The relay App.tsx makes for a subagent's pane, over the kept drafts. */
async function relay(
  key: string,
  handle: RefObject<ComposerHandle | null>,
  send?: (text: string, attachments: ComposerAttachment[]) => boolean,
): Promise<ComposerRelay> {
  const drafts = await import("../src/agent-session/acpmux/subagents/subagentDrafts");
  return {
    placeholder: "Message Helper",
    handle,
    initial: drafts.subagentDraft(key),
    onChange: (draft) => drafts.keepSubagentDraft(key, draft),
    subscribe: (listener) => drafts.subscribeSubagentDraft(key, listener),
    onUnplacedQuotes: (quotes) => {
      const kept = drafts.subagentDraft(key);
      drafts.keepSubagentDraft(key, { ...kept, text: [kept.text, ...quotes].filter(Boolean).join("\n\n") });
    },
    attachRefusal: "A message to a subagent can only be text.",
    ...(send && { send }),
  };
}

function Chips() {
  return <span className="chat-chips" />;
}

/** The composer the subagent's pane draws: the chat's, with every chat prop, and the relay. */
async function mount(composerRelay: ComposerRelay, wait = true) {
  const { createRoot } = await import("react-dom/client");
  const { Composer } = await import("../src/agent-session/acpmux/Composer");
  const chatSession = "chat-1";
  const snapshot = noChat([], {
    sessionId: chatSession,
    isWorking: true,
    summary: { sessionId: chatSession, harness: "claude", cwd: "/Users/you/src/app", turnCount: 3 },
  });
  const chatHandle = createRef<ComposerHandle>();
  root ??= createRoot(host);
  const element = (
    <Composer
      snapshot={snapshot}
      sessionId={chatSession}
      chips={Chips}
      onSend={() => {
        throw new Error("a relayed composer sent to the chat");
      }}
      onStop={() => {
        throw new Error("a relayed composer stopped the chat's turn");
      }}
      handle={chatHandle}
      relay={composerRelay}
    />
  );
  if (wait) {
    await act(async () => root!.render(element));
    await until(() => !!host.querySelector(".acpmux-md"));
  } else act(() => root!.render(element));
  return chatHandle;
}

const prompt = () => host.querySelector(".acpmux-md")?.textContent ?? "";

test("the subagent's composer is the chat's Composer, named for the subagent, with none of the chat's controls", async () => {
  const handle = createRef<ComposerHandle>();
  const chatHandle = await mount(await relay("chat\u001fnamed", handle));
  const form = host.querySelector("form.acpmux-composer")!;
  expect(form.getAttribute("data-cmux-component")).toBe("Composer");
  expect(form.hasAttribute("data-composer-relay")).toBe(true);
  expect(form.querySelector('[role="combobox"]')?.getAttribute("aria-label")).toBe("Message Helper");
  // The chat's turn runs, but the relay offers no Stop; its chips are not drawn.
  expect(form.querySelector(".acpmux-cancel")).toBeNull();
  expect(form.querySelector(".chat-chips")).toBeNull();
  // The relay's handle is the relay's; the chat's stays unset, so the chat's held prompts never land here.
  expect(handle.current).not.toBeNull();
  expect(chatHandle.current).toBeNull();
});

test("a quote goes into the subagent's prompt through the relay's handle", async () => {
  const handle = createRef<ComposerHandle>();
  await mount(await relay("chat\u001fhelper", handle));
  await act(async () => handle.current!.quoteReply("> Neither blocks the five problems."));
  await until(() => prompt().includes("Neither blocks"));
  expect(host.querySelector(".acpmux-md blockquote")?.textContent).toContain("Neither blocks the five problems.");
  act(() => root?.unmount());
  root = undefined;
  expect(handle.current).toBeNull();
});

test("a quote taken before the editor is ready survives the pane closing and comes back on reopen", async () => {
  const { subagentDraft } = await import("../src/agent-session/acpmux/subagents/subagentDrafts");
  const key = "chat\u001fearly";
  const handle = createRef<ComposerHandle>();
  // The first render's effects run, so the handle is set, but the editor is still being made.
  await mount(await relay(key, handle), false);
  expect(handle.current).not.toBeNull();
  act(() => handle.current!.quoteReply("> Early quote."));
  await settle();
  act(() => root!.unmount());
  root = undefined;
  expect(subagentDraft(key).text).toContain("> Early quote.");
  await mount(await relay(key, createRef<ComposerHandle>()));
  await until(() => prompt().includes("Early quote."));
  expect(prompt()).toContain("Early quote.");
});

test("a send goes to the relay and clears the prompt; a failed one comes back into it whole", async () => {
  const drafts = await import("../src/agent-session/acpmux/subagents/subagentDrafts");
  const key = "chat\u001fsender";
  drafts.keepSubagentDraft(key, { text: "Also check the retry tests", attachments: [] });
  const handle = createRef<ComposerHandle>();
  const sent: string[] = [];
  await mount(
    await relay(key, handle, (text) => {
      sent.push(text);
      return true;
    }),
  );
  await until(() => prompt().includes("Also check the retry tests"));
  await act(async () => {
    handle.current!.send();
  });
  await until(() => sent.length === 1 && prompt() === "");
  expect(sent[0]).toContain("Also check the retry tests");
  await settle();
  expect(drafts.subagentDraft(key).text).toBe("");
  // The chat refused it: the message comes back (App.tsx afterFailedSend), and the prompt shows it.
  act(() => drafts.restoreSubagentDraft(key, { text: "Also check the retry tests", attachments: [] }));
  await until(() => prompt().includes("Also check the retry tests"));
});
