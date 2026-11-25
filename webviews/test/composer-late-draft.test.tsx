// l10n-allow-file: test fixture prompts, not shipped UI.
// A Cloud start's page takes its seed's draft before the sending tab is handed off, so it can draw
// out of sight first (AgentPaneDrawFirst); what the person typed in that tab in between reaches the
// page as `lateDraft` and the composer puts it in the earlier text's place (ComposerHandle.lateDraft).
// The handler once called state setters a refactor had removed, which threw on every late draft.
import { afterAll, afterEach, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act, createRef } from "react";
import type { Root } from "react-dom/client";
import { noChat } from "../src/gallery/fixtures/acpmux";
import type { MarkdownFieldElement } from "../src/agent-session/acpmux/MarkdownField";
import type { ComposerHandle } from "../src/agent-session/acpmux/Composer";
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


test("a late draft takes the handshake's draft's place in the prompt", async () => {
  const typed: string[] = [];
  const handle = await render("late-draft-replaces", typed);
  await act(async () => markdownField().insertTyped("and the"));
  await until(() => prompt() === "and the", "the handshake's draft");
  await act(async () => handle.current!.lateDraft("and the nightly", "and the"));
  await until(() => prompt() === "and the nightly", "the late draft");
  expect(markdownField().value()).toBe("and the nightly");
});

test("a late draft keeps text typed on the page meanwhile, after it", async () => {
  const typed: string[] = [];
  const handle = await render("late-draft-keeps", typed);
  await act(async () => markdownField().insertTyped("mine"));
  await until(() => prompt() === "mine", "the typed text");
  await act(async () => handle.current!.lateDraft("and the nightly", "and the"));
  await until(() => prompt().includes("and the nightly"), "the late draft");
  expect(markdownField().value()).toBe("and the nightly\n\nmine");
});

test("a late draft into an empty prompt is the prompt", async () => {
  const typed: string[] = [];
  const handle = await render("late-draft-empty", typed);
  await act(async () => handle.current!.lateDraft("typed late", ""));
  await until(() => prompt() === "typed late", "the late draft");
  expect(markdownField().value()).toBe("typed late");
});
