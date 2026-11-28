// Leo 2026-11-24: "big disaster in Mango! i had a draft too that i wanted to send :(". His draft
// was kept, but twice over: a prompt that came back into the composer (a send that failed while the
// chat loaded, one taken back from the queue) went in ahead of the same text the draft had already
// put there. A prompt coming back is merged with the prompt by the draft rule (`mergedDraft`): what
// is already there is never doubled, and two different texts are both kept.
import { afterAll, afterEach, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act, createRef } from "react";
import type { Root } from "react-dom/client";
import { noChat } from "../src/gallery/fixtures/acpmux";
import type { MarkdownFieldElement } from "../src/agent-session/acpmux/MarkdownField";
import type { ComposerHandle } from "../src/agent-session/acpmux/Composer";
import { restoredPrompt } from "../src/agent-session/acpmux/composerDraft";
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

test("a prompt that comes back into a prompt already holding it is not doubled", async () => {
  const typed: string[] = [];
  const handle = await render("restore-same", typed);
  await act(async () => markdownField().insertTyped("ship the fix"));
  await until(() => prompt() === "ship the fix", "the draft");
  await act(async () => handle.current!.restore("ship the fix", []));
  await settle();
  expect(prompt()).toBe("ship the fix");
  // Behind what is there (a hold giving back a later prompt) too.
  await act(async () => handle.current!.restore("ship the fix", [], true));
  await settle();
  expect(prompt()).toBe("ship the fix");
});

test("a different prompt that comes back still goes ahead of what was typed", async () => {
  const typed: string[] = [];
  const handle = await render("restore-other", typed);
  await act(async () => markdownField().insertTyped("typed since"));
  await until(() => prompt() === "typed since", "the draft");
  await act(async () => handle.current!.restore("came back", []));
  await until(() => prompt().includes("came back"), "the restored prompt");
  expect(markdownField().value()).toBe("came back\n\ntyped since");
});

test("restoredPrompt keeps both texts once, in order", () => {
  expect(restoredPrompt("", "back")).toBe("back");
  expect(restoredPrompt("typed", "")).toBe("typed");
  expect(restoredPrompt("same", "same")).toBe("same");
  expect(restoredPrompt("same", "same", true)).toBe("same");
  expect(restoredPrompt("typed", "back")).toBe("back\n\ntyped");
  expect(restoredPrompt("typed", "back", true)).toBe("typed\n\nback");
  // Already the merge's result: a second restore of the same prompt adds nothing.
  expect(restoredPrompt("back\n\ntyped", "back")).toBe("back\n\ntyped");
  expect(restoredPrompt("typed\n\nback", "back", true)).toBe("typed\n\nback");
  // Never by substring: "bug" and "debugging" are two prompts.
  expect(restoredPrompt("debugging", "bug")).toBe("bug\n\ndebugging");
});
