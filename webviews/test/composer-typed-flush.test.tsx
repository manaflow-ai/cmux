// A typed key's draft writes (the remount cache, acpmux's draft, a new chat's unsent draft) and its typing
// presence run once after the key, never in its own task (goals/typing-latency.md: together about 0.5 ms a key on
// Linux WebKit, Composer.tsx `flushTyped`). No draft is lost for it: a send, a blur, the page hidden, a switch and
// the composer going write what was typed at once.
import { afterAll, afterEach, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act, createRef } from "react";
import type { Root } from "react-dom/client";
import { noChat } from "../src/gallery/fixtures/acpmux";
import type { MarkdownFieldElement } from "../src/agent-session/acpmux/MarkdownField";
import type { ComposerHandle } from "../src/agent-session/acpmux/Composer";
import { readPersistedDraft } from "../src/agent-session/acpmux/composerDraft";
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
  // A saved draft (composerDraft.ts, the page's localStorage remount cache) would come back in
  // the next test's prompt. These tests open chats of their own: the module's pending draft
  // writes outlive a test file.
  dom.window.localStorage.clear();
});

afterAll(async () => {
  await teardownDom(saved, { window: dom.window, scope });
});

function Chips() {
  return null;
}

/// The chat each report named: the composer's own, never the next chat's during a switch.
const typedIn: Array<string | undefined> = [];

async function render(sessionId: string, typed: string[], handle = createRef<ComposerHandle>()) {
  const { createRoot } = await import("react-dom/client");
  const { Composer } = await import("../src/agent-session/acpmux/Composer");
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
        onSend={() => true}
        onStop={() => {}}
        onProject={() => {}}
        onNewChat={() => {}}
        onTyping={(text, id) => {
          typed.push(text);
          typedIn.push(id);
        }}
        handle={handle}
        localName="studio"
        projectChoices={[{ cwd: "/Users/you/src/app", label: "app" }]}
      />,
    ),
  );
  await until(() => !!host.querySelector('[role="combobox"]'), "the editor");
  return handle;
}

async function until(ready: () => boolean, what: string) {
  const deadline = performance.now() + 2_000;
  while (!ready()) {
    if (performance.now() > deadline) throw new Error(`timed out waiting for ${what}`);
    await settle();
  }
}

const settle = () =>
  act(async () => {
    await new Promise((resolve) => setTimeout(resolve, 0));
  });

const prompt = () => host.querySelector('[role="combobox"]')?.textContent ?? "";
const markdownField = () => host.querySelector<MarkdownFieldElement>(".acpmux-md-field")!.acpmuxMarkdownField!;

const editor = () => host.querySelector<HTMLElement>('[role="combobox"]')!;

/// The key's own task: what is saved right after the key, before any timer runs.
const typeKey = (text: string) =>
  act(() => {
    markdownField().insertTyped(text);
  });
const draftOf = (session: string) => readPersistedDraft(session);

test("a typed key saves nothing in its own task; the draft is saved just after", async () => {
  const typed: string[] = [];
  await render("flush-later", typed);
  await settle();
  await typeKey("h");
  await typeKey("i");
  expect(prompt()).toBe("hi");
  expect(draftOf("flush-later")).toBeUndefined();
  expect(typed).toEqual([]);
  await until(() => draftOf("flush-later") === "hi", "the draft saved after the keys");
  // One presence report for the keys typed together, with the text as it is.
  expect(typed).toEqual(["hi"]);
});

test("a blur saves what was typed at once", async () => {
  const typed: string[] = [];
  await render("flush-blur", typed);
  await settle();
  await typeKey("kept on blur");
  expect(draftOf("flush-blur")).toBeUndefined();
  await act(
    () => void editor().dispatchEvent(new dom.window.FocusEvent("focusout", { bubbles: true, relatedTarget: null })),
  );
  expect(draftOf("flush-blur")).toBe("kept on blur");
  expect(typed).toEqual(["kept on blur"]);
});

test("the page hidden saves what was typed at once", async () => {
  await render("flush-hidden", []);
  await settle();
  await typeKey("kept on pagehide");
  expect(draftOf("flush-hidden")).toBeUndefined();
  await act(() => void dom.window.dispatchEvent(new dom.window.Event("pagehide")));
  expect(draftOf("flush-hidden")).toBe("kept on pagehide");
});

test("the composer going saves what was typed", async () => {
  await render("flush-unmount", []);
  await settle();
  await typeKey("kept on unmount");
  expect(draftOf("flush-unmount")).toBeUndefined();
  act(() => root?.unmount());
  root = undefined;
  expect(draftOf("flush-unmount")).toBe("kept on unmount");
});

test("a quit's settle writes what was typed before it waits", async () => {
  const handle = await render("flush-settle", []);
  await settle();
  await typeKey("kept on quit");
  expect(draftOf("flush-settle")).toBeUndefined();
  let settled = false;
  await act(async () => {
    void handle.current!.settleDraft().then(() => (settled = true));
  });
  expect(draftOf("flush-settle")).toBe("kept on quit");
  await until(() => settled, "the settle");
});

test("a send sends the exact text typed, says it typed, then that it stopped", async () => {
  const typed: string[] = [];
  const sent: string[] = [];
  const { createRoot } = await import("react-dom/client");
  const { Composer } = await import("../src/agent-session/acpmux/Composer");
  const sessionId = "flush-send";
  const handle = createRef<ComposerHandle>();
  root ??= createRoot(host);
  await act(async () =>
    root!.render(
      <Composer
        snapshot={noChat([], {
          sessionId,
          summary: { sessionId, harness: "claude", cwd: "/Users/you/src/app", turnCount: 0 },
        })}
        sessionId={sessionId}
        chips={Chips}
        onSend={(text) => {
          sent.push(text);
          return true;
        }}
        onStop={() => {}}
        onProject={() => {}}
        onNewChat={() => {}}
        onTyping={(text) => typed.push(text)}
        handle={handle}
        localName="studio"
        projectChoices={[{ cwd: "/Users/you/src/app", label: "app" }]}
      />,
    ),
  );
  await until(() => !!host.querySelector('[role="combobox"]'), "the editor");
  await settle();
  await typeKey("ship ");
  await typeKey("it");
  await act(async () => void handle.current!.send());
  expect(sent).toEqual(["ship it"]);
  await until(() => prompt() === "", "the clear");
  expect(typed).toEqual(["ship it", ""]);
  await until(() => draftOf("flush-send") === undefined, "the cleared draft");
});

test("a switch saves the text typed for the chat it was typed in, not the next one", async () => {
  await render("flush-from", []);
  await settle();
  await typeKey("for the first chat");
  expect(draftOf("flush-from")).toBeUndefined();
  await render("flush-to", []);
  await until(() => prompt() === "", "the next chat's empty prompt");
  expect(draftOf("flush-from")).toBe("for the first chat");
  await settle();
  // Whatever write is still held for the next chat goes out now: none carries the first chat's text.
  await act(() => void dom.window.dispatchEvent(new dom.window.Event("pagehide")));
  expect(draftOf("flush-to")).toBeUndefined();
});
