// The composer's draft against acpmux's, over every ordering the cmux#28204 reviews walked: load,
// edit, send, unmount, remount, a write sent and answered, a read answered, a reconnect. One rule
// (composerDraft.ts hydratedDraft): once the person touched the prompt (an edit or a send, in this
// mount or an earlier one, or a write still on its way), the prompt is the draft and acpmux's is
// never merged in; text typed before the page ever read the chat's draft is kept beside acpmux's;
// an untouched prompt shows acpmux's draft.
import { afterAll, afterEach, beforeAll, expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import path from "node:path";
import { JSDOM } from "jsdom";
import { act, createRef } from "react";
import type { Root } from "react-dom/client";
import { noChat } from "../src/gallery/fixtures/acpmux";
import type { MarkdownFieldElement } from "../src/agent-session/acpmux/MarkdownField";
import type { ComposerHandle } from "../src/agent-session/acpmux/Composer";
import { MAX_DRAFT_CHARS, hydratedDraft, notifyDraftActionsChanged } from "../src/agent-session/acpmux/composerDraft";

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

async function type(text: string) {
  await act(async () => markdownField()!.setCaret(Number.MAX_SAFE_INTEGER));
  await act(async () => markdownField()!.insertTyped(text));
}

/// acpmux's drafts for one chat, with reads and writes the steps can hold and answer.
function gatedDaemon(saved: string | undefined) {
  const state = {
    held: saved,
    holdReads: false,
    holdWrites: false,
    reads: [] as (() => void)[],
    writes: [] as (() => void)[],
    written: [] as string[],
  };
  const actions = {
    "chat.readDraft": () =>
      new Promise((done) => {
        // Answers with what acpmux holds when it answers, not when it was asked.
        const answer = () => done({ draft: state.held ?? null });
        if (state.holdReads) state.reads.push(answer);
        else answer();
      }),
    "chat.writeDraft": ({ text }: Record<string, unknown>) =>
      new Promise<void>((done) => {
        const land = () => {
          state.written.push(String(text));
          state.held = String(text).trim() ? String(text) : undefined;
          done();
        };
        if (state.holdWrites) state.writes.push(land);
        else land();
      }),
  };
  return { state, actions };
}

type Row = { name: string; saved?: string; steps: string[]; text: string; held?: string };

/// Each row's steps, in order; `expect` is the prompt and acpmux's draft once every held read and
/// write is answered. Rows 1-3 are the three cases the reviews found.
const rows: Row[] = [
  {
    name: "1 buy bread: replaced while disconnected, away and back, then reconnect",
    saved: "buy milk",
    steps: ["connect", "load", "disconnect", "edit:buy bread", "away", "load", "connect"],
    text: "buy bread",
    held: "buy bread",
  },
  {
    name: "2 in-flight write: unmounted and remounted before acpmux answers the write",
    saved: "buy milk",
    steps: ["connect", "load", "hold writes", "edit:buy bread", "unmount", "load", "ack writes"],
    text: "buy bread",
    held: "buy bread",
  },
  {
    name: "3 send during read: a cached draft edited and sent before the read answers",
    saved: "buy milk",
    steps: ["connect", "load", "unmount", "hold reads", "load", "edit:buy bread", "send", "answer reads"],
    text: "",
  },
  {
    name: "typed before the page ever read the draft: both kept, the saved one first",
    saved: "saved",
    steps: ["hold reads", "connect", "load", "edit:typed", "answer reads"],
    text: "saved\n\ntyped",
    held: "saved\n\ntyped",
  },
  {
    name: "untouched revisit after another client changed the draft: acpmux's",
    saved: "v1",
    steps: ["connect", "load", "unmount", "external:v2", "load"],
    text: "v2",
    held: "v2",
  },
  {
    name: "untouched prompt, acpmux's draft changed while disconnected, reconnect: acpmux's",
    saved: "v1",
    steps: ["connect", "load", "disconnect", "external:v2", "connect"],
    text: "v2",
    held: "v2",
  },
  {
    name: "an answered edit, then away and back: the edit",
    saved: "buy milk",
    steps: ["connect", "load", "edit:buy bread", "unmount", "load"],
    text: "buy bread",
    held: "buy bread",
  },
  {
    name: "edited while disconnected, reconnect in place",
    saved: "buy milk",
    steps: ["connect", "load", "disconnect", "edit:buy bread", "connect"],
    text: "buy bread",
    held: "buy bread",
  },
  {
    name: "write out, reconnect before its answer",
    saved: "buy milk",
    steps: ["connect", "load", "hold writes", "edit:buy bread", "disconnect", "connect", "ack writes"],
    text: "buy bread",
    held: "buy bread",
  },
  {
    name: "write out, remount, the read answers before the write does",
    saved: "buy milk",
    steps: [
      "connect",
      "load",
      "hold writes",
      "edit:buy bread",
      "hold reads",
      "unmount",
      "load",
      "answer reads",
      "ack writes",
    ],
    text: "buy bread",
    held: "buy bread",
  },
  {
    // cmux#28204 review at 470bd8b0: the read settled nothing (the write was out), and the write's
    // answer settled nothing either, so the edit stayed "local" for good and won over v2.
    name: "the write answered after a read, then another pane changed the draft: theirs on return",
    saved: "buy milk",
    steps: [
      "connect",
      "load",
      "hold writes",
      "edit:buy bread",
      "hold reads",
      "unmount",
      "load",
      "answer reads",
      "ack writes",
      "unmount",
      "external:v2",
      "load",
    ],
    text: "v2",
    held: "v2",
  },
  {
    name: "a send's clear answered after a read, then another pane typed: theirs on return",
    saved: "buy milk",
    steps: [
      "connect",
      "load",
      "hold writes",
      "edit:buy bread",
      "send",
      "hold reads",
      "unmount",
      "load",
      "answer reads",
      "ack writes",
      "unmount",
      "external:v2",
      "load",
    ],
    text: "v2",
    held: "v2",
  },
  {
    name: "sent after the load, remounted before the clear is answered",
    saved: "buy milk",
    steps: ["connect", "load", "hold writes", "edit:buy bread", "send", "unmount", "load", "ack writes"],
    text: "",
  },
  {
    name: "sent before the first read answered",
    saved: "buy milk",
    steps: ["hold reads", "connect", "load", "edit:buy bread", "send", "answer reads"],
    text: "",
  },
  {
    name: "saved bug, typed debugging before the first read: both kept (no substring dedupe)",
    saved: "bug",
    steps: ["hold reads", "connect", "load", "edit:debugging", "answer reads"],
    text: "bug\n\ndebugging",
    held: "bug\n\ndebugging",
  },
  {
    name: "the saved draft typed again exactly before the first read: kept once",
    saved: "same",
    steps: ["hold reads", "connect", "load", "edit:same", "answer reads"],
    text: "same",
    held: "same",
  },
  {
    name: "after the first read, an edit that contains the old draft is the draft as typed",
    saved: "bug",
    steps: ["connect", "load", "unmount", "hold reads", "load", "edit:debugging", "answer reads"],
    text: "debugging",
    held: "debugging",
  },
  {
    name: "edited, then the read answers with nothing saved",
    steps: ["hold reads", "connect", "load", "edit:buy bread", "answer reads"],
    text: "buy bread",
    held: "buy bread",
  },
];

let rowNumber = 0;
for (const row of rows) {
  test(`orderings: ${row.name}`, async () => {
    // A chat of its own per row: the page keeps its per-chat bookkeeping for its life.
    const sessionId = `ordering-${++rowNumber}`;
    const { state, actions } = gatedDaemon(row.saved);
    let handle = createRef<ComposerHandle>();
    const release = async () => {
      for (let round = 0; round < 4; round += 1) {
        for (const answer of state.reads.splice(0)) await act(async () => answer());
        for (const land of state.writes.splice(0)) await act(async () => land());
        await settle();
      }
    };
    for (const step of row.steps) {
      if (step === "connect") {
        page().cmuxAcpmuxActions = actions as never;
        await act(async () => notifyDraftActionsChanged());
      } else if (step === "disconnect") {
        delete page().cmuxAcpmuxActions;
        await act(async () => notifyDraftActionsChanged());
      } else if (step === "load") {
        handle = await render(sessionId, {}, handle);
      } else if (step === "away") {
        handle = await render(`${sessionId}-other`, {}, handle);
      } else if (step === "unmount") {
        act(() => root?.unmount());
        root = undefined;
        handle = createRef<ComposerHandle>();
      } else if (step.startsWith("edit:")) {
        const next = step.slice("edit:".length);
        // The person replaces the prompt: select all, type.
        await act(async () => markdownField()!.type(""));
        await type(next);
        await until(() => prompt() === next, `the edit to ${next}`);
      } else if (step === "send") {
        await act(async () => void handle.current!.send());
        await until(() => prompt() === "", "the send's clear");
      } else if (step === "hold reads") state.holdReads = true;
      else if (step === "hold writes") state.holdWrites = true;
      else if (step === "answer reads") {
        state.holdReads = false;
        for (const answer of state.reads.splice(0)) await act(async () => answer());
      } else if (step === "ack writes") {
        state.holdWrites = false;
        for (const land of state.writes.splice(0)) await act(async () => land());
      } else if (step.startsWith("external:")) state.held = step.slice("external:".length);
      else throw new Error(`unknown step ${step}`);
      await settle();
      await settle();
    }
    state.holdReads = false;
    state.holdWrites = false;
    await release();
    expect(prompt()).toBe(row.text);
    expect(state.held).toBe(row.held);
    // acpmux's old draft never went back merged into the person's text.
    if (row.saved && row.text && !row.text.includes(row.saved))
      expect(state.written.some((text) => text.includes(row.saved!))).toBe(false);
  });
}

test("hydratedDraft: the one rule", () => {
  const base = { current: "", restored: undefined, read: false, edited: false, sent: false, pendingWrite: false };
  // Untouched, read before: acpmux's draft fills the prompt.
  expect(hydratedDraft({ ...base, current: "old", restored: "new", read: true })).toEqual({
    text: "new",
    shown: true,
    write: false,
  });
  // Untouched, first read: whatever the prompt held is kept beside it.
  expect(hydratedDraft({ ...base, current: "cached", restored: "saved" }).text).toBe("saved\n\ncached");
  // Typed before any read: both kept.
  expect(hydratedDraft({ ...base, current: "typed", restored: "saved", edited: true }).text).toBe("saved\n\ntyped");
  // Touched after a read, a write on its way, or sent: the prompt as it is.
  for (const touched of [{ edited: true, read: true }, { pendingWrite: true }, { sent: true }])
    expect(hydratedDraft({ ...base, current: "buy bread", restored: "buy milk", ...touched }).text).toBe("buy bread");
  expect(hydratedDraft({ ...base, current: "", restored: "buy milk", sent: true })).toEqual({
    text: "",
    shown: false,
    write: true,
  });
});

test("a quit's read answers before the load's: the editor and acpmux both keep saved and typed", async () => {
  // cmux#28204 review at ffdbd9d1: settleDraft marked the draft read and saved the merge while the
  // editor still held only "typed"; the load's read then kept "typed" and wrote it over the merge.
  const sessionId = "ordering-quit-read-first";
  const { state, actions } = gatedDaemon("saved");
  state.holdReads = true;
  page().cmuxAcpmuxActions = actions as never;
  await act(async () => notifyDraftActionsChanged());
  const handle = await render(sessionId);
  await settle();
  await type("typed");
  await until(() => prompt() === "typed", "the typed text");
  await settle();
  // The load's read is held; the quit's read joins it.
  const quit = handle.current!.settleDraft();
  await settle();
  expect(state.reads.length).toBe(2);
  const [loadRead, quitRead] = state.reads.splice(0);
  await act(async () => quitRead!());
  await act(async () => quit);
  await settle();
  await act(async () => loadRead!());
  await settle();
  await settle();
  state.holdReads = false;
  expect(prompt()).toBe("saved\n\ntyped");
  expect(state.held).toBe("saved\n\ntyped");
  // One more edit keeps "saved".
  await type("!");
  await until(() => prompt() === "saved\n\ntyped!", "the next edit");
  await settle();
  await settle();
  expect(state.held).toBe("saved\n\ntyped!");
});

// cmux#28204 review at b7cddbbf: a saved draft one character under the limit plus "x" typed before
// the read merged to a text past the limit. The stores refuse such a text (acpmux's draft_set errors;
// AgentUnsentDrafts.set turned it into nil, removing the saved draft), so a quit lost the draft.
// The chosen behaviour when "saved\n\ntyped" does not fit: no merge is written, the saved draft
// stays exactly as it was, and the editor keeps what the person typed. Nothing is lost.
// The limit as the stores keep it (acpmux's Hub::MAX_COMPOSER_DRAFT_CHARS, AgentUnsentDrafts).
const LIMIT = 1_000_000;
const tooLong = (text: string) => Array.from(text).length > LIMIT;

test("the web's draft limit is acpmux's and AgentUnsentDrafts'", () => {
  const repo = path.resolve(import.meta.dir, "../..");
  const rust = readFileSync(path.join(repo, "cmux-tui/crates/acpmux/src/hub/mod.rs"), "utf8");
  const swift = readFileSync(
    path.join(repo, "Packages/macOS/CmuxNext/Sources/CmuxNextAgentPane/AgentUnsentDrafts.swift"),
    "utf8",
  );
  const number = (match: RegExpMatchArray | null) => Number(match?.[1]?.replaceAll("_", ""));
  expect(number(rust.match(/MAX_COMPOSER_DRAFT_CHARS: usize = ([\d_]+);/))).toBe(LIMIT);
  expect(number(swift.match(/static let maximumCharacters = ([\d_]+)/))).toBe(LIMIT);
  expect(MAX_DRAFT_CHARS).toBe(LIMIT);
});

test("a saved draft at the limit and text typed before the read: nothing written over it, the typing kept", async () => {
  const sessionId = "ordering-over-limit";
  const saved = "s".repeat(LIMIT - 1);
  const { state, actions } = gatedDaemon(saved);
  state.holdReads = true;
  page().cmuxAcpmuxActions = actions as never;
  await act(async () => notifyDraftActionsChanged());
  const handle = await render(sessionId);
  await settle();
  await type("x");
  await until(() => prompt() === "x", "the typed text");
  await settle();
  state.holdReads = false;
  for (const answer of state.reads.splice(0)) await act(async () => answer());
  await settle();
  await settle();
  expect(prompt()).toBe("x");
  expect(state.held).toBe(saved);
  // A later key and a quit keep it too: the typed text never goes over the saved draft.
  await type("y");
  await until(() => prompt() === "xy", "the next key");
  await settle();
  await act(async () => handle.current!.settleDraft());
  await settle();
  expect(state.held).toBe(saved);
  expect(state.written.some((text) => tooLong(text) || !text.trim())).toBe(false);
});

test("a saved draft left apart at the limit, then the typing sent: the saved draft stays and comes back", async () => {
  // cmux#28204 review at c736d691: the send marked the prompt sent, and the next read took the
  // empty prompt as the draft and wrote it over the saved one the overflow had kept.
  const sessionId = "ordering-over-limit-sent";
  const saved = "s".repeat(LIMIT - 1);
  const { state, actions } = gatedDaemon(saved);
  state.holdReads = true;
  page().cmuxAcpmuxActions = actions as never;
  await act(async () => notifyDraftActionsChanged());
  const handle = await render(sessionId);
  await settle();
  await type("x");
  await until(() => prompt() === "x", "the typed text");
  await settle();
  state.holdReads = false;
  for (const answer of state.reads.splice(0)) await act(async () => answer());
  await settle();
  await settle();
  expect(prompt()).toBe("x");
  await act(async () => void handle.current!.send());
  await until(() => prompt() === "", "the send's clear");
  await settle();
  // The next read (actions reinstalled after a reconnect) finds the saved draft and shows it.
  await act(async () => notifyDraftActionsChanged());
  await until(() => prompt() === saved, "the saved draft back");
  await settle();
  expect(state.held).toBe(saved);
  expect(state.written.some((text) => !text.trim())).toBe(false);
});

test("a read asked before an edit's write was answered never puts the old draft back", async () => {
  // cmux#28204 review at 027ee470: the read captured "buy milk", the edit's write of "buy bread" was
  // answered (which settles the edit), then the late read put "buy milk" back over it.
  const sessionId = "ordering-stale-read";
  let held: string | undefined = "buy milk";
  let holdReads = false;
  const late: (() => void)[] = [];
  const actions = {
    // Answers with what acpmux held when it was asked.
    "chat.readDraft": () =>
      new Promise((done) => {
        const answer = { draft: held ?? null };
        if (holdReads) late.push(() => done(answer));
        else done(answer);
      }),
    "chat.writeDraft": async ({ text }: Record<string, unknown>) => {
      held = String(text).trim() ? String(text) : undefined;
    },
  };
  page().cmuxAcpmuxActions = actions as never;
  await act(async () => notifyDraftActionsChanged());
  await render(sessionId);
  await until(() => prompt() === "buy milk", "the saved draft");
  await settle();
  // A reconnect asks again; that read is held, with "buy milk" in it.
  holdReads = true;
  await act(async () => notifyDraftActionsChanged());
  await settle();
  expect(late.length).toBe(1);
  holdReads = false;
  await act(async () => markdownField()!.type(""));
  await type("buy bread");
  await until(() => prompt() === "buy bread", "the edit");
  await settle();
  await settle();
  expect(held).toBe("buy bread");
  for (const answer of late.splice(0)) await act(async () => answer());
  await settle();
  await settle();
  expect(prompt()).toBe("buy bread");
  expect(held).toBe("buy bread");
});

test("a quit after a reconnect took another pane's draft never writes it over that pane's later one", async () => {
  // cmux#28204 review at 9df3d754: the page saved "A", a reconnect showed another pane's "B", that
  // pane then saved "C"; the quit compared "B" with the page's old "A" and wrote "B" over "C".
  const sessionId = "ordering-quit-after-remote";
  const { state, actions } = gatedDaemon("v0");
  page().cmuxAcpmuxActions = actions as never;
  await act(async () => notifyDraftActionsChanged());
  const handle = await render(sessionId);
  await until(() => prompt() === "v0", "the saved draft");
  await act(async () => markdownField()!.type(""));
  await type("A");
  await until(() => prompt() === "A", "the edit");
  await settle();
  await settle();
  expect(state.held).toBe("A");
  delete page().cmuxAcpmuxActions;
  await act(async () => notifyDraftActionsChanged());
  state.held = "B";
  page().cmuxAcpmuxActions = actions as never;
  await act(async () => notifyDraftActionsChanged());
  await until(() => prompt() === "B", "the other pane's draft");
  await settle();
  state.held = "C";
  await act(async () => handle.current!.settleDraft());
  await settle();
  expect(state.held).toBe("C");
  expect(state.written).not.toContain("B");
});

test("a saved draft and typed text that fit the limit exactly: merged and written", async () => {
  const sessionId = "ordering-at-limit";
  const saved = "s".repeat(LIMIT - 3);
  const { state, actions } = gatedDaemon(saved);
  state.holdReads = true;
  page().cmuxAcpmuxActions = actions as never;
  await act(async () => notifyDraftActionsChanged());
  await render(sessionId);
  await settle();
  await type("x");
  await until(() => prompt() === "x", "the typed text");
  await settle();
  state.holdReads = false;
  for (const answer of state.reads.splice(0)) await act(async () => answer());
  await settle();
  await settle();
  const merged = `${saved}\n\nx`;
  expect(merged.length).toBe(LIMIT);
  expect(prompt()).toBe(merged);
  expect(state.held).toBe(merged);
});

test("a new chat's kept draft at the limit arriving after the person typed: the host keeps it, the typing stays", async () => {
  const saved = "k".repeat(LIMIT - 1);
  const sent: string[] = [];
  const onUnsentDraft = (text: string) => void sent.push(text);
  const handle = await render(undefined, { onUnsentDraft });
  await type("x");
  await until(() => prompt() === "x", "the typed text");
  await settle();
  // The handshake's seed (the tab's kept draft) comes after the key.
  const before = sent.length;
  await render(undefined, { draft: saved, onUnsentDraft }, handle);
  await settle();
  await settle();
  expect(prompt()).toBe("x");
  await type("y");
  await until(() => prompt() === "xy", "the next key");
  await settle();
  await act(async () => handle.current!.settleDraft());
  const after = sent.slice(before);
  // Nothing past the limit, and no blank, went to the host; what it holds last is the kept draft.
  expect(after.some((text) => tooLong(text) || !text.trim())).toBe(false);
  expect(after.at(-1)).toBe(saved);
});

test("a new chat's kept draft and typed text that fit exactly: merged and sent", async () => {
  const saved = "k".repeat(LIMIT - 3);
  const sent: string[] = [];
  const onUnsentDraft = (text: string) => void sent.push(text);
  const handle = await render(undefined, { onUnsentDraft });
  await type("x");
  await until(() => prompt() === "x", "the typed text");
  await settle();
  await render(undefined, { draft: saved, onUnsentDraft }, handle);
  const merged = `${saved}\n\nx`;
  await until(() => prompt() === merged, "the merged prompt");
  await act(async () => handle.current!.settleDraft());
  expect(sent.at(-1)).toBe(merged);
});
