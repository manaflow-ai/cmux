// Leo 2026-10-29: "WHY THE FUCK ARE YOU STILL CLEARING MY FUCKING COMPOSER DRAFT WHEN I TYPE BEFORE
// FUCKING LOADING IM ASSUMING MY PAST DRAFTS MAY ALSO GET FUCKED TOO". Text typed into the composer
// before the chat finished loading (its session attached, acpmux's draft read, the handshake's
// seed) survives the load, a saved draft survives the typing, an empty editor never clears a saved
// draft while loading, and the person's own clear still clears.
import { afterAll, afterEach, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act, createRef } from "react";
import type { Root } from "react-dom/client";
import { noChat } from "../src/gallery/fixtures/acpmux";
import type { MarkdownFieldElement } from "../src/agent-session/acpmux/MarkdownField";
import type { ComposerHandle } from "../src/agent-session/acpmux/Composer";
import { hydratedDraft, mergedDraft, notifyDraftActionsChanged } from "../src/agent-session/acpmux/composerDraft";

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

async function render(
  sessionId: string | undefined,
  options: { draft?: string; draftGeneration?: number; onUnsentDraft?: (text: string, generation: number) => void } = {},
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
        draftGeneration={options.draftGeneration}
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
function daemon(drafts: Record<string, string> = {}, generation = 0) {
  const held = new Map(Object.entries(drafts));
  const generations = new Map(Object.keys(drafts).map((key) => [key, generation]));
  const writes: { sessionId: string; text: string }[] = [];
  const actions = {
    "chat.readDraft": async ({ sessionId }: Record<string, unknown>) => ({
      draft: held.get(String(sessionId)) ?? null,
      generation: generations.get(String(sessionId)) ?? 0,
    }),
    "chat.writeDraft": async ({ sessionId, text, generation }: Record<string, unknown>) => {
      if (Number(generation ?? 0) < (generations.get(String(sessionId)) ?? 0)) return;
      generations.set(String(sessionId), Number(generation ?? 0));
      writes.push({ sessionId: String(sessionId), text: String(text) });
      if (String(text).trim()) held.set(String(sessionId), String(text));
      else held.delete(String(sessionId));
    },
  };
  return {
    held,
    generations,
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

test("the merge keeps both texts once, the saved draft first", () => {
  expect(mergedDraft("typed", "saved")).toBe("saved\n\ntyped");
  expect(mergedDraft("", "saved")).toBe("saved");
  expect(mergedDraft("typed", undefined)).toBe("typed");
  expect(mergedDraft("saved, then more", "saved")).toBe("saved, then more");
  expect(mergedDraft("typed", "saved\n\ntyped")).toBe("saved\n\ntyped");
  expect(mergedDraft("world again", "hello world")).toBe("hello world again");
  expect(mergedDraft("saved", "saved text")).toBe("saved text");
  // A first read of acpmux's draft merges; an empty editor never writes over it.
  expect(hydratedDraft({ current: "", restored: "saved", edited: true, pendingWrite: true, firstRead: true })).toEqual({
    text: "saved",
    shown: true,
    write: false,
  });
  // After the page read it, the person's own clear (queued) stands.
  expect(hydratedDraft({ current: "", restored: "saved", edited: true, pendingWrite: true, firstRead: false })).toEqual(
    {
      text: "",
      shown: false,
      write: false,
    },
  );
});

test("(a) text typed before the chat's session attached is still there after it loads", async () => {
  const acpmux = daemon();
  await acpmux.connect();
  await render(undefined);
  await type("typed before load");
  await until(() => prompt() === "typed before load", "the typed text");
  // The handshake names the chat: before, this reset the prompt to empty.
  await render("load-a");
  await settle();
  await settle();
  expect(prompt()).toBe("typed before load");
  await until(() => acpmux.held.get("load-a") === "typed before load", "acpmux to keep it");
});

test("(b) a saved draft and text typed before acpmux answered: both are kept", async () => {
  const acpmux = daemon({ "load-b": "the saved draft" });
  // The page has the chat but not yet its connection (no action map).
  await render("load-b");
  await type("typed while loading");
  await until(() => prompt() === "typed while loading", "the typed text");
  await settle();
  expect(acpmux.writes).toEqual([]);
  await acpmux.connect();
  await until(() => prompt() === "the saved draft\n\ntyped while loading", "the merged prompt");
  await until(() => acpmux.held.get("load-b") === "the saved draft\n\ntyped while loading", "acpmux to keep both");
  expect(acpmux.writes.some((write) => write.text === "typed while loading")).toBe(false);
});

test("(b) a new chat's kept draft arriving after the person typed joins their text", async () => {
  const sent: string[] = [];
  const onUnsentDraft = (text: string) => void sent.push(text);
  await render(undefined, { onUnsentDraft });
  await type("typed first");
  await until(() => prompt() === "typed first", "the typed text");
  // The handshake's seed (the tab's kept draft) comes after the keys.
  await render(undefined, { draft: "kept from last run", onUnsentDraft });
  await until(() => prompt() === "kept from last run\n\ntyped first", "the merged prompt");
});

test("(c) an empty composer never clears a saved draft while the chat loads", async () => {
  const acpmux = daemon({ "load-c": "the saved draft" });
  await render("load-c");
  // Typed, then deleted, before the draft was read: no clear of a draft never shown.
  await type("x");
  await act(async () => markdownField()!.type(""));
  await settle();
  await acpmux.connect();
  await until(() => prompt() === "the saved draft", "the saved draft");
  await settle();
  expect(acpmux.writes.filter((write) => !write.text.trim())).toEqual([]);
  expect(acpmux.held.get("load-c")).toBe("the saved draft");
});

test("(c) a read that fails is no empty draft: typing then waits for the read", async () => {
  const acpmux = daemon({ "load-c2": "the saved draft" });
  page().cmuxAcpmuxActions = {
    "chat.readDraft": async () => {
      throw new Error("acpmux did not answer in time");
    },
    "chat.writeDraft": async () => {
      throw new Error("acpmux did not answer in time");
    },
  };
  await render("load-c2");
  await settle();
  await type("typed during the outage");
  await settle();
  await acpmux.connect();
  await until(() => prompt() === "the saved draft\n\ntyped during the outage", "the merged prompt");
  await until(() => acpmux.held.get("load-c2") === "the saved draft\n\ntyped during the outage", "acpmux to keep both");
});

test("(d) the person's clear and a send still clear the saved draft", async () => {
  const acpmux = daemon({ "load-d": "the saved draft" });
  await acpmux.connect();
  const handle = await render("load-d");
  await until(() => prompt() === "the saved draft", "the saved draft");
  await act(async () => markdownField()!.type(""));
  await until(() => !acpmux.held.has("load-d"), "the clear");
  await type("ship it");
  await until(() => acpmux.held.get("load-d") === "ship it", "the new draft");
  await act(async () => void handle.current!.send());
  await until(() => prompt() === "", "the send's clear");
  await until(() => !acpmux.held.has("load-d"), "the send to clear acpmux's draft");
});


test("an offline send leaves a tombstone before a remount, and later edits never restore sent text", async () => {
  const handle = await render("generation-offline-send");
  await type("look at these");
  await settle();
  await act(async () => void handle.current!.send());
  await until(() => prompt() === "", "the send clear");
  await act(async () => root!.unmount());
  root = undefined;
  await render("generation-offline-send");
  expect(prompt()).toBe("");
  await type("what the heck");
  const acpmux = daemon({ "generation-offline-send": "look at these" });
  await acpmux.connect();
  await until(() => acpmux.held.get("generation-offline-send") === "what the heck", "new generation to persist");
  expect(prompt()).toBe("what the heck");
  expect(acpmux.generations.get("generation-offline-send")).toBeGreaterThan(0);
});

test("a fresh paste supersedes a draft read already in flight", async () => {
  let answer: ((state: unknown) => void) | undefined;
  const writes: { text: string; generation: number }[] = [];
  page().cmuxAcpmuxActions = {
    "chat.readDraft": () => new Promise((resolve) => { answer = resolve; }),
    "chat.writeDraft": async (state) => { writes.push(state as { text: string; generation: number }); },
  };
  await render("generation-paste");
  const event = new dom.window.Event("paste", { bubbles: true, cancelable: true });
  Object.defineProperty(event, "clipboardData", { value: {
    files: [], types: ["text/plain"], getData: (kind: string) => kind === "text/plain" ? "fresh paste" : "",
  } });
  await act(async () => host.querySelector('[role="combobox"]')!.dispatchEvent(event));
  await until(() => prompt() === "fresh paste", "the paste");
  await act(async () => answer!({ draft: "stale saved text", generation: 0 }));
  await settle();
  expect(prompt()).toBe("fresh paste");
  expect(writes.at(-1)?.text).toBe("fresh paste");
  expect(writes.at(-1)?.generation).toBeGreaterThan(0);
});

test("a late update in the same nonzero generation keeps both texts", async () => {
  const acpmux = daemon({ "generation-same": "saved first" }, 7);
  await render("generation-same", { draftGeneration: 7 });
  await type("typed after");
  await acpmux.connect();
  await until(() => prompt() === "saved first\n\ntyped after", "same-generation merge");
  expect(acpmux.generations.get("generation-same")).toBe(7);
});

test("an intentional clear while loading rejects the old saved generation", async () => {
  await render("generation-clear");
  await type("delete this");
  await act(async () => {
    host.querySelector('[role="combobox"]')!.dispatchEvent(new dom.window.KeyboardEvent("keydown", { key: "Backspace", bubbles: true }));
    markdownField()!.type("");
  });
  const acpmux = daemon({ "generation-clear": "older unseen draft" });
  await acpmux.connect();
  await settle();
  expect(prompt()).toBe("");
  await until(() => !acpmux.held.has("generation-clear"), "clear tombstone to persist");
});
