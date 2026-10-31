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

test("the merge keeps both texts once, the saved draft first", () => {
  expect(mergedDraft("typed", "saved")).toBe("saved\n\ntyped");
  expect(mergedDraft("", "saved")).toBe("saved");
  expect(mergedDraft("typed", undefined)).toBe("typed");
  expect(mergedDraft("saved", "saved")).toBe("saved");
  expect(mergedDraft("saved\n\ntyped", "saved")).toBe("saved\n\ntyped");
  // Exact dedupe only, never by substring: both drafts stay.
  expect(mergedDraft("debugging", "bug")).toBe("bug\n\ndebugging");
  expect(mergedDraft("saved, then more", "saved")).toBe("saved\n\nsaved, then more");
  expect(mergedDraft("typed", "saved\n\ntyped")).toBe("saved\n\ntyped");
  // The read's rule itself is covered in composer-draft-orderings.test.tsx (hydratedDraft).
  const none = { read: false, sent: false, pendingWrite: false };
  // A first read of acpmux's draft merges; an empty editor never writes over it.
  expect(hydratedDraft({ ...none, current: "", restored: "saved", edited: true })).toEqual({
    text: "saved",
    shown: true,
    write: false,
  });
  // A write still queued (an edit or a clear made after an earlier read) stands: acpmux's older
  // draft is not merged into it.
  expect(
    hydratedDraft({ ...none, current: "buy bread", restored: "buy milk", edited: true, pendingWrite: true }),
  ).toEqual({
    text: "buy bread",
    shown: false,
    write: false,
  });
  // After the page read it, the person's own clear (queued) stands.
  expect(
    hydratedDraft({ ...none, current: "", restored: "saved", edited: true, pendingWrite: true, read: true }),
  ).toEqual({
    text: "",
    shown: false,
    write: false,
  });
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

test("(e) an edit queued while disconnected survives switching away and back before the reconnect", async () => {
  // cmux#28204 review: leaving the chat forgot that its draft was read, so the read after the
  // reconnect counted as a first read and merged acpmux's old draft into the queued replacement.
  const acpmux = daemon({ "load-e": "buy milk" });
  await acpmux.connect();
  await render("load-e");
  await until(() => prompt() === "buy milk", "the saved draft");
  // The connection drops: the replacement is queued, not yet acpmux's.
  delete page().cmuxAcpmuxActions;
  await act(async () => notifyDraftActionsChanged());
  await act(async () => markdownField()!.type("buy bread"));
  await until(() => prompt() === "buy bread", "the replacement");
  await settle();
  // Away to another chat and back, still disconnected.
  await render("load-e-other");
  await settle();
  await render("load-e");
  await settle();
  await acpmux.connect();
  await until(() => acpmux.held.get("load-e") === "buy bread", "acpmux to take the queued replacement");
  await settle();
  await settle();
  expect(prompt()).toBe("buy bread");
  expect(acpmux.held.get("load-e")).toBe("buy bread");
  expect(acpmux.writes.some((write) => write.text.includes("buy milk\n\nbuy bread"))).toBe(false);
});

test("(f) an edit still on its way to acpmux survives leaving and coming back before its answer", async () => {
  // cmux#28204 review: the drain took a write off the queue before acpmux answered it, so leaving
  // forgot the read and the remount's read merged acpmux's older draft into the replacement.
  const acpmux = daemon({ "load-f": "buy milk" });
  await acpmux.connect();
  await render("load-f");
  await until(() => prompt() === "buy milk", "the saved draft");
  // acpmux holds each write until the test answers it.
  const answers: (() => void)[] = [];
  const write = page().cmuxAcpmuxActions!["chat.writeDraft"]!;
  page().cmuxAcpmuxActions!["chat.writeDraft"] = (params) =>
    new Promise((done) => answers.push(() => void write(params).then(done)));
  await act(async () => markdownField()!.type("buy bread"));
  await until(() => answers.length > 0, "the replacement's write to go out");
  // The composer goes and comes back while that write is out: the read still answers "buy milk".
  act(() => root?.unmount());
  root = undefined;
  await render("load-f");
  await settle();
  await settle();
  expect(prompt()).toBe("buy bread");
  // acpmux answers: it holds the replacement, and nothing merged the old draft into it.
  for (const answer of answers.splice(0)) await act(async () => answer());
  await settle();
  for (const answer of answers.splice(0)) await act(async () => answer());
  await settle();
  expect(prompt()).toBe("buy bread");
  expect(acpmux.held.get("load-f")).toBe("buy bread");
  expect(acpmux.writes.some((entry) => entry.text.includes("buy milk\n\nbuy bread"))).toBe(false);
});
