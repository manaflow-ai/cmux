// https://github.com/manaflow-ai/cmux/issues/48612: typing in an agent chat lagged under CPU load.
// Every key wrote the whole draft to acpmux (`chat.writeDraft`), and acpmux saved the chat's meta,
// journaled it and re-dated its list row for each one, on the cores the pane types on. The
// composer now writes once typing pauses (composerDraft.ts `writeTypedDraft`), while a clear, a
// send, a quit and the composer going still write at once, so nothing typed is lost.
import { afterAll, afterEach, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act, createRef } from "react";
import type { Root } from "react-dom/client";
import { noChat } from "../src/gallery/fixtures/acpmux";
import type { MarkdownFieldElement } from "../src/agent-session/acpmux/MarkdownField";
import type { ComposerHandle } from "../src/agent-session/acpmux/Composer";
import {
  draftWriteLimits,
  notifyDraftActionsChanged,
  settlePendingDraftWrites,
} from "../src/agent-session/acpmux/composerDraft";
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
  // jsdom lays nothing out and its Range has no rects: ProseMirror measures one to scroll.
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
  dom.window.localStorage.clear();
  delete page().cmuxAcpmuxActions;
});

afterAll(async () => {
  await teardownDom(saved, { window: dom.window, scope });
});

function Chips() {
  return null;
}

async function render(
  sessionId: string | undefined,
  options: { draft?: string; onUnsentDraft?: (text: string) => void } = {},
  handle = createRef<ComposerHandle>(),
) {
  const { createRoot } = await import("react-dom/client");
  const { Composer } = await import("../src/agent-session/acpmux/Composer");
  const snapshot = noChat(
    [],
    sessionId ? { sessionId, summary: { sessionId, harness: "claude", cwd: "/Users/you/src/app", turnCount: 0 } } : {},
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
        handle={handle}
        localName="studio"
        projectChoices={[{ cwd: "/Users/you/src/app", label: "app" }]}
        {...(options.draft ? { draft: options.draft } : {})}
        {...(options.onUnsentDraft ? { onUnsentDraft: options.onUnsentDraft } : {})}
      />,
    ),
  );
  await until(() => !!host.querySelector('[role="combobox"]'), "the editor");
  return handle;
}

async function until(ready: () => boolean, what: string) {
  const deadline = performance.now() + 2_000;
  while (!ready()) {
    if (performance.now() > deadline) throw new Error(`timed out waiting for ${what} (prompt: ${prompt()})`);
    await settle();
  }
}

const settle = () =>
  act(async () => {
    await new Promise((resolve) => setTimeout(resolve, 0));
  });

const prompt = () => markdownField()?.value() ?? "";
const markdownField = () => host.querySelector<MarkdownFieldElement>(".acpmux-md-field")?.acpmuxMarkdownField;
const page = () =>
  dom.window as unknown as {
    cmuxAcpmuxActions?: Record<string, (params: Record<string, unknown>) => Promise<unknown>>;
  };

/// acpmux's drafts, as `chat.readDraft` / `chat.writeDraft` reach them.
function daemon(drafts: Record<string, string> = {}) {
  const held = new Map(Object.entries(drafts));
  const writes: { sessionId: string; text: string }[] = [];
  const actions = {
    "chat.readDraft": async ({ sessionId }: Record<string, unknown>) => ({
      draft: held.get(String(sessionId)) ?? null,
    }),
    "chat.writeDraft": async ({ sessionId, text }: Record<string, unknown>) => {
      writes.push({ sessionId: String(sessionId), text: String(text) });
      if (String(text).trim()) held.set(String(sessionId), String(text));
      else held.delete(String(sessionId));
    },
  };
  return {
    held,
    writes,
    /// The native action map arrives (the connection is up).
    async connect() {
      page().cmuxAcpmuxActions = actions;
      await act(async () => notifyDraftActionsChanged());
    },
  };
}

async function type(text: string) {
  await act(async () => markdownField()!.setCaret(Number.MAX_SAFE_INTEGER));
  await act(async () => markdownField()!.insertTyped(text));
}

test("a burst of typed keys is two draft writes: the draft's first key, then the rest once typing pauses", async () => {
  const acpmux = daemon();
  await acpmux.connect();
  await render("typing-a");
  await settle();
  const before = acpmux.writes.length;
  for (const key of "buy bread") await type(key);
  await until(() => prompt() === "buy bread", "the typed text");
  await settle();
  // Mid-burst: the first key told acpmux a draft exists (its `hasDraft`, which an update's
  // install-when-idle reads); the rest are the page's (the remount cache has them), acpmux not asked.
  expect(acpmux.writes.slice(before)).toEqual([{ sessionId: "typing-a", text: "b" }]);
  expect(dom.window.localStorage.getItem("cmux.acpmux.composer-draft.typing-a")).toBe("buy bread");
  // Typing pauses: the one write of the rest goes (draftWriteLimits.typedIdleMs).
  await until(() => acpmux.writes.length > before + 1, "the write once typing pauses");
  await settle();
  expect(acpmux.writes.slice(before)).toEqual([
    { sessionId: "typing-a", text: "b" },
    { sessionId: "typing-a", text: "buy bread" },
  ]);
  expect(acpmux.held.get("typing-a")).toBe("buy bread");
});

test("a quit right after a key does not wait for the pause: acpmux holds the last key", async () => {
  // acpmux holds a draft, so the key is not a draft's first: it waits for the pause.
  const acpmux = daemon({ "typing-b": "ship" });
  await acpmux.connect();
  await render("typing-b");
  await until(() => prompt() === "ship", "the saved draft");
  await settle();
  const before = acpmux.writes.length;
  await type(" it");
  await until(() => prompt() === "ship it", "the typed text");
  expect(acpmux.writes.length).toBe(before);
  await act(async () => settlePendingDraftWrites());
  expect(acpmux.held.get("typing-b")).toBe("ship it");
});

test("the composer going right after a key writes the key", async () => {
  const acpmux = daemon({ "typing-c": "keep" });
  await acpmux.connect();
  await render("typing-c");
  await until(() => prompt() === "keep", "the saved draft");
  await settle();
  const before = acpmux.writes.length;
  await type(" me");
  await until(() => prompt() === "keep me", "the typed text");
  expect(acpmux.writes.length).toBe(before);
  act(() => root?.unmount());
  root = undefined;
  await settle();
  expect(acpmux.held.get("typing-c")).toBe("keep me");
});

test("clearing the prompt writes the clear at once", async () => {
  const acpmux = daemon({ "typing-d": "old draft" });
  await acpmux.connect();
  await render("typing-d");
  await until(() => prompt() === "old draft", "the saved draft");
  await act(async () => markdownField()!.type(""));
  await settle();
  await settle();
  expect(acpmux.held.has("typing-d")).toBe(false);
});

test("a person who types on without pausing still has acpmux catch up within the cap", async () => {
  // A renderer that dies mid-typing reloads with the remount cache and acpmux's draft, and merges the
  // two: the cap keeps acpmux at most `typedMaxWaitMs` behind. Here the pause is far off (10 s), so
  // only the cap can send the write.
  const limits = { ...draftWriteLimits };
  Object.assign(draftWriteLimits, { typedIdleMs: 10_000, typedMaxWaitMs: 50 });
  try {
    // acpmux already holds a draft, so no key here is a draft's first.
    const acpmux = daemon({ "typing-e": "still" });
    await acpmux.connect();
    await render("typing-e");
    await until(() => prompt() === "still", "the saved draft");
    await settle();
    const before = acpmux.writes.length;
    await type(" typing");
    await until(() => prompt() === "still typing", "the typed text");
    await until(() => acpmux.writes.length > before, "the write at the cap");
    expect(acpmux.held.get("typing-e")).toBe("still typing");
  } finally {
    Object.assign(draftWriteLimits, limits);
  }
});
