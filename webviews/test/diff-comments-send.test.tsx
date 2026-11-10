// "Send to agent" in the diff viewer: every saved comment goes to the diff's chat as one prompt
// (file:line, the quoted lines, the comment), and only the comments sent leave the page. A refused
// send keeps them all and says so; the host clears its store only after the chat took the prompt.
import { afterAll, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act } from "react";
import type { Root } from "react-dom/client";
import { teardownDom } from "./support/domTeardown";

const scope = globalThis as Record<string, unknown>;
const keys = ["window", "document", "navigator", "HTMLElement", "customElements", "IS_REACT_ACT_ENVIRONMENT"] as const;
const saved = keys.map((key) => [key, key in scope, scope[key]] as const);
let root: Root | undefined;
let host: HTMLElement;
let posts: Array<{ method: string; params: Record<string, unknown> }> = [];
let refuseSend = true;

beforeAll(() => {
  const { window } = new JSDOM("<!doctype html><div id=root></div>", { url: "http://localhost/" });
  (window as unknown as { webkit: unknown }).webkit = {
    messageHandlers: {
      cmuxDiffComments: {
        postMessage: async (message: { method: string; params: Record<string, unknown> }) => {
          posts.push(message);
          if (message.method === "comments.send" && refuseSend)
            return { ok: false, error: { code: "cmux.diff.no_chat", userMessage: "No chat owns this diff." } };
          return { ok: true, value: {} };
        },
      },
    },
  };
  Object.assign(scope, {
    window,
    document: window.document,
    navigator: window.navigator,
    HTMLElement: window.HTMLElement,
    customElements: window.customElements,
    IS_REACT_ACT_ENVIRONMENT: true,
  });
  host = window.document.getElementById("root")!;
});

afterAll(async () => {
  act(() => root?.unmount());
  await teardownDom(saved, { scope });
});

type Comment = import("../src/comments/types").DiffCommentRecord;

const comment = (id: string, filePath: string, line: number): Comment => ({
  id,
  filePath,
  side: "additions",
  startLine: line,
  endLine: line,
  lineText: "x",
  message: `fix ${id}`,
  submissionText: `Review comment on ${filePath} line ${line} (new version):\n\nfix ${id}\n`,
  createdAt: "2026-11-07T00:00:00.000Z",
  updatedAt: "2026-11-07T00:00:00.000Z",
});

test("the prompt lists every comment once, by file then line", async () => {
  const { commentsPromptText } = await import("../src/comments/format");
  const text = commentsPromptText([
    comment("b", "src/b.ts", 3),
    comment("a2", "src/a.ts", 9),
    comment("a1", "src/a.ts", 2),
  ]);
  expect(text).toBe(
    [
      "Review comment on src/a.ts line 2 (new version):\n\nfix a1",
      "Review comment on src/a.ts line 9 (new version):\n\nfix a2",
      "Review comment on src/b.ts line 3 (new version):\n\nfix b",
    ].join("\n\n") + "\n",
  );
});

test("a refused send keeps the comments; a sent one clears only what it sent", async () => {
  const { createRoot } = await import("react-dom/client");
  const { useDiffComments } = await import("../src/diff-viewer/useDiffComments");
  const { initialAppState } = await import("../src/diff-viewer/state");
  type Hook = ReturnType<typeof useDiffComments>;
  const state = {
    current: { ...initialAppState({ payload: {} } as never, "ready" as never), comments: [] as Comment[] },
  };
  state.current.comments = [comment("c1", "a.ts", 1), comment("c2", "b.ts", 4)];
  const dispatched: Array<{ type: string; ids?: readonly string[] }> = [];
  let hook!: Hook;
  function Probe() {
    hook = useDiffComments({
      bridgeAvailable: true,
      canSend: true,
      dispatch: ((action: { type: string; ids?: readonly string[] }) => dispatched.push(action)) as never,
      latestState: state as never,
      repoRoot: "/repo",
    });
    return null;
  }
  root = createRoot(host);
  act(() => root!.render(<Probe />));
  expect(hook.canSend).toBe(true);

  await act(async () => hook.send());
  expect(posts.map((post) => post.method)).toEqual(["comments.send"]);
  expect(posts[0]!.params).toMatchObject({ repoRoot: "/repo", ids: ["c1", "c2"] });
  expect(String(posts[0]!.params.text)).toContain("Review comment on a.ts line 1");
  expect(hook.sendState).toBe("failed");
  expect(dispatched).toEqual([]);

  refuseSend = false;
  await act(async () => hook.send());
  expect(hook.sendState).toBe("idle");
  expect(dispatched).toEqual([{ type: "remove-comments", ids: ["c1", "c2"] }]);
});

test("the reducer removes the sent comments together and keeps a newer one", async () => {
  const { initialAppState, reducer } = await import("../src/diff-viewer/state");
  const start = { ...initialAppState({ payload: {} } as never, "ready" as never) };
  start.comments = [comment("c1", "a.ts", 1), comment("c2", "a.ts", 2), comment("c3", "a.ts", 3)];
  const next = reducer(start, { type: "remove-comments", ids: ["c1", "c2"] });
  expect(next.comments.map((entry) => entry.id)).toEqual(["c3"]);
});

test("a retry of the same comments sends the same prompt id, so the chat gets the review once", async () => {
  const { installPageDiffComments } = await import("../src/comments/bridge");
  const { createRoot } = await import("react-dom/client");
  const { useDiffComments } = await import("../src/diff-viewer/useDiffComments");
  const { initialAppState } = await import("../src/diff-viewer/state");
  const sends: Array<{ ids: unknown; opid?: string }> = [];
  let clearFails = true;
  installPageDiffComments({
    call: async (
      _op: string,
      body: { method: string; params: Record<string, unknown> },
      options?: { opid?: string },
    ) => {
      sends.push({ ids: body.params.ids, opid: options?.opid });
      // The chat took the prompt, but the host could not clear the comments.
      if (clearFails) throw Object.assign(new Error("store busy"), { code: "operation.failed" });
      return {};
    },
  } as never);
  const savedWebkit = (window as unknown as { webkit: unknown }).webkit;
  (window as unknown as { webkit: unknown }).webkit = undefined;
  try {
    type Hook = ReturnType<typeof useDiffComments>;
    const state = {
      current: { ...initialAppState({ payload: {} } as never, "ready" as never), comments: [] as Comment[] },
    };
    state.current.comments = [comment("c1", "a.ts", 1)];
    let hook!: Hook;
    function Probe() {
      hook = useDiffComments({
        bridgeAvailable: true,
        canSend: true,
        dispatch: (() => {}) as never,
        latestState: state as never,
        repoRoot: "/repo",
      });
      return null;
    }
    const probe = createRoot(document.createElement("div"));
    act(() => probe.render(<Probe />));
    await act(async () => hook.send());
    expect(hook.sendState).toBe("failed");
    // A comment added before the retry does not change the batch the chat may already have.
    state.current.comments = [...state.current.comments, comment("c2", "b.ts", 2)];
    clearFails = false;
    await act(async () => hook.send());
    expect(hook.sendState).toBe("idle");
    expect(sends.length).toBe(2);
    expect(sends[0]!.opid).toBeDefined();
    expect(sends[1]!.opid).toBe(sends[0]!.opid);
    expect(sends[1]!.ids).toEqual(["c1"]);
    act(() => probe.unmount());
  } finally {
    installPageDiffComments(null);
    (window as unknown as { webkit: unknown }).webkit = savedWebkit;
  }
});

test("a comment edited while its send is on the way stays, with its edit", async () => {
  const { installPageDiffComments } = await import("../src/comments/bridge");
  const { createRoot } = await import("react-dom/client");
  const { useDiffComments } = await import("../src/diff-viewer/useDiffComments");
  const { initialAppState } = await import("../src/diff-viewer/state");
  let finish!: (value: unknown) => void;
  let sent: Record<string, unknown> = {};
  installPageDiffComments({
    call: (_op: string, body: { params: Record<string, unknown> }) => {
      sent = body.params;
      return new Promise((resolve) => (finish = resolve));
    },
  } as never);
  const savedWebkit = (window as unknown as { webkit: unknown }).webkit;
  (window as unknown as { webkit: unknown }).webkit = undefined;
  try {
    type Hook = ReturnType<typeof useDiffComments>;
    const state = {
      current: { ...initialAppState({ payload: {} } as never, "ready" as never), comments: [] as Comment[] },
    };
    state.current.comments = [comment("c1", "a.ts", 1), comment("c2", "a.ts", 2)];
    const dispatched: Array<{ type: string; ids?: readonly string[] }> = [];
    let hook!: Hook;
    function Probe() {
      hook = useDiffComments({
        bridgeAvailable: true,
        canSend: true,
        dispatch: ((action: { type: string; ids?: readonly string[] }) => dispatched.push(action)) as never,
        latestState: state as never,
        repoRoot: "/repo",
      });
      return null;
    }
    const probe = createRoot(document.createElement("div"));
    act(() => probe.render(<Probe />));
    act(() => hook.send());
    expect(sent.versions).toEqual({ c1: "2026-11-07T00:00:00.000Z", c2: "2026-11-07T00:00:00.000Z" });
    // c2 is edited while the send is on its way; the host kept it (its version moved on).
    state.current.comments = [
      comment("c1", "a.ts", 1),
      { ...comment("c2", "a.ts", 2), updatedAt: "2026-11-07T00:01:00.000Z" },
    ];
    await act(async () => finish({ cleared: ["c1"] }));
    expect(dispatched).toEqual([{ type: "remove-comments", ids: ["c1"] }]);
    expect(hook.sendState).toBe("idle");
    act(() => probe.unmount());
  } finally {
    installPageDiffComments(null);
    (window as unknown as { webkit: unknown }).webkit = savedWebkit;
  }
});

test("pressing Comment twice on the same draft saves it under one opid", async () => {
  const { installPageDiffComments } = await import("../src/comments/bridge");
  const { createRoot } = await import("react-dom/client");
  const { useDiffComments } = await import("../src/diff-viewer/useDiffComments");
  const { initialAppState } = await import("../src/diff-viewer/state");
  const opids: Array<string | undefined> = [];
  installPageDiffComments({
    call: (_op: string, _body: unknown, options?: { opid?: string }) => {
      opids.push(options?.opid);
      return new Promise(() => {});
    },
  } as never);
  const savedWebkit = (window as unknown as { webkit: unknown }).webkit;
  (window as unknown as { webkit: unknown }).webkit = undefined;
  try {
    type Hook = ReturnType<typeof useDiffComments>;
    const draft = { itemId: "a.ts", side: "additions" as const, startLine: 1, endLine: 1 };
    const state = { current: { ...initialAppState({ payload: {} } as never, "ready" as never), draft } };
    const item = { id: "a.ts", fileDiff: { name: "a.ts", hunks: [] } } as never;
    let hook!: Hook;
    function Probe() {
      hook = useDiffComments({
        bridgeAvailable: true,
        canSend: true,
        dispatch: (() => {}) as never,
        latestState: state as never,
        repoRoot: "/repo",
      });
      return null;
    }
    const probe = createRoot(document.createElement("div"));
    act(() => probe.render(<Probe />));
    act(() => hook.saveDraft(item, "Use 5"));
    act(() => hook.saveDraft(item, "Use 5"));
    act(() => hook.saveDraft(item, "Use 6"));
    expect(opids).toHaveLength(3);
    expect(opids[0]).toBeString();
    expect(opids[1]).toBe(opids[0]);
    expect(opids[2]).not.toBe(opids[0]);
    act(() => probe.unmount());
  } finally {
    installPageDiffComments(null);
    (window as unknown as { webkit: unknown }).webkit = savedWebkit;
  }
});
