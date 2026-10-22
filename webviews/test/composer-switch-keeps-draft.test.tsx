// Lucas 2026-10-19: picking another provider's model in the composer is a harness switch, which
// starts a new session; the composer swapped to that session's (empty) saved draft and the typed
// prompt vanished. During a switch the prompt stays and becomes the new session's draft. Moving to
// another chat still shows that chat's own draft.
import { afterAll, afterEach, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act } from "react";
import type { Root } from "react-dom/client";
import { noChat } from "../src/gallery/fixtures/acpmux";

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

async function render(sessionId: string, props: { draft?: string; switching?: boolean } = {}) {
  const { createRoot } = await import("react-dom/client");
  const { Composer } = await import("../src/agent-session/acpmux/Composer");
  const snapshot = noChat(
    [],
    sessionId ? { sessionId, summary: { sessionId, harness: "codex", cwd: "/Users/you/src/app", turnCount: 0 } } : {},
  );
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
        localName="studio"
        projectChoices={[{ cwd: "/Users/you/src/app", label: "app" }]}
        draft={props.draft}
        switching={props.switching}
      />,
    ),
  );
}

const prompt = () => host.querySelector('[role="combobox"]')?.textContent ?? "";

test("a harness switch keeps the typed prompt through the new session", async () => {
  await render("chat-a", { draft: "compare these cars" });
  expect(prompt()).toBe("compare these cars");
  // The pick: the old chat is hidden while the new session starts, then it arrives.
  await render("", { switching: true });
  expect(prompt()).toBe("compare these cars");
  await render("chat-b", { switching: true });
  expect(prompt()).toBe("compare these cars");
  // The switch settles on the new session; a later move to another chat shows that chat's draft.
  await render("chat-b");
  expect(prompt()).toBe("compare these cars");
  await render("chat-c");
  expect(prompt()).toBe("");
});

test("a switch that ends in the same render as its session change still keeps the prompt", async () => {
  await render("chat-a", { draft: "compare these cars" });
  await render("", { switching: true });
  // The intent clears in the batch that brings the new session.
  await render("chat-b");
  expect(prompt()).toBe("compare these cars");
});

test("moving to a chat with its own draft mid-switch keeps that chat's draft", async () => {
  const { writePersistedDraft } = await import("../src/agent-session/acpmux/composerDraft");
  writePersistedDraft("chat-d", "my other draft");
  await render("chat-a", { draft: "compare these cars" });
  await render("chat-d", { switching: true });
  expect(prompt()).toBe("my other draft");
});

test("moving to another chat shows that chat's draft, not the typed prompt", async () => {
  await render("chat-a", { draft: "compare these cars" });
  expect(prompt()).toBe("compare these cars");
  await render("chat-c");
  expect(prompt()).toBe("");
});

test("changing the composer look keeps the same prompt field, draft and session", async () => {
  const { setComposerLook } = await import("../src/agent-session/acpmux/composerLook");
  await render("look-chat", { draft: "keep this prompt while changing the look" });
  const field = host.querySelector('[role="combobox"]');
  const form = host.querySelector(".acpmux-composer");
  try {
    await act(async () => setComposerLook("codex"));
    expect(form?.getAttribute("data-composer-look")).toBe("codex");
    expect(host.querySelector(".acpmux-composer-foot")).toBeNull();
    expect(host.querySelector('[role="combobox"]')).toBe(field);
    expect(prompt()).toBe("keep this prompt while changing the look");
    expect(dom.window.localStorage.getItem("cmux.composer.look")).toBe("codex");

    // A fresh mount reads the persisted look and this chat's own saved draft.
    await act(async () => root?.unmount());
    root = undefined;
    await render("look-chat");
    expect(host.querySelector(".acpmux-composer")?.getAttribute("data-composer-look")).toBe("codex");
    expect(prompt()).toBe("keep this prompt while changing the look");

    await act(async () => setComposerLook("claude"));
    expect(host.querySelector(".acpmux-composer-foot")).not.toBeNull();
    expect(prompt()).toBe("keep this prompt while changing the look");
  } finally {
    await act(async () => setComposerLook("claude"));
  }
});

test("a look pick still applies when storage rejects writes but exposes the previous value", async () => {
  const { setComposerLook } = await import("../src/agent-session/acpmux/composerLook");
  const storage = scope.localStorage;
  scope.localStorage = {
    getItem: () => "claude",
    setItem: () => {
      throw new Error("storage unavailable");
    },
  };
  try {
    await render("storage-denied");
    await act(async () => setComposerLook("codex"));
    expect(host.querySelector(".acpmux-composer")?.getAttribute("data-composer-look")).toBe("codex");
  } finally {
    scope.localStorage = storage;
    await act(async () => setComposerLook("claude"));
  }
});
