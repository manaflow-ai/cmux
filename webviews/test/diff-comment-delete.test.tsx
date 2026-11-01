// A review comment leaves the diff viewer at once when it is deleted, and the host removes it from
// its store. When the host cannot, the comment is still stored (and would go to the agent with the
// next submit), so it comes back instead of the page saying it is gone.
import { afterAll, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act } from "react";
import type { Root } from "react-dom/client";

const scope = globalThis as Record<string, unknown>;
const keys = ["window", "document", "navigator", "HTMLElement", "IS_REACT_ACT_ENVIRONMENT"] as const;
const saved = keys.map((key) => [key, key in scope, scope[key]] as const);
let root: Root | undefined;
let host: HTMLElement;
let posts: Array<{ method: string }> = [];
let failDelete = true;

beforeAll(() => {
  const { window } = new JSDOM("<!doctype html><div id=root></div>", { url: "http://localhost/" });
  (window as unknown as { webkit: unknown }).webkit = {
    messageHandlers: {
      cmuxDiffComments: {
        postMessage: async (message: { method: string }) => {
          posts.push(message);
          if (message.method === "comments.delete" && failDelete)
            return { ok: false, error: { userMessage: "The store is locked." } };
          return { ok: true, value: null };
        },
      },
    },
  };
  Object.assign(scope, {
    window,
    document: window.document,
    navigator: window.navigator,
    HTMLElement: window.HTMLElement,
    IS_REACT_ACT_ENVIRONMENT: true,
  });
  host = window.document.getElementById("root")!;
});

afterAll(() => {
  act(() => root?.unmount());
  for (const [key, had, value] of saved) {
    if (had) scope[key] = value;
    else delete scope[key];
  }
});

test("a comment the host could not delete comes back, and one it deleted stays gone", async () => {
  const { createRoot } = await import("react-dom/client");
  const { useDiffComments } = await import("../src/diff-viewer/useDiffComments");
  const { initialAppState } = await import("../src/diff-viewer/state");
  type Hook = ReturnType<typeof useDiffComments>;
  type Record = Parameters<Hook["remove"]>[0];
  const comment = (id: string): Record => ({
    id,
    filePath: "a.ts",
    side: "additions",
    startLine: 1,
    endLine: 1,
    lineText: "x",
    message: id,
    createdAt: "2026-11-01T00:00:00.000Z",
    updatedAt: "2026-11-01T00:00:00.000Z",
  });
  let comments: Record[] = [comment("c1"), comment("c2")];
  let hook!: Hook;
  const dispatched: Array<{ type: string; id?: string; comment?: Record }> = [];
  const dispatch = (action: { type: string; id?: string; comment?: Record }) => {
    dispatched.push(action);
    if (action.type === "remove-comment") comments = comments.filter((entry) => entry.id !== action.id);
    if (action.type === "upsert-comment" && !comments.some((entry) => entry.id === action.comment!.id))
      comments = [...comments, action.comment!];
  };
  const state = { current: initialAppState({ payload: {} } as never, "ready" as never) };
  function Probe() {
    hook = useDiffComments({
      bridgeAvailable: true,
      dispatch: dispatch as never,
      latestState: state as never,
      repoRoot: "/repo",
    });
    return null;
  }
  root = createRoot(host);
  act(() => root!.render(<Probe />));

  await act(async () => hook.remove(comment("c1")));
  expect(posts.map((post) => post.method)).toEqual(["comments.delete"]);
  expect(comments.map((entry) => entry.id).sort()).toEqual(["c1", "c2"]);

  failDelete = false;
  await act(async () => hook.remove(comment("c2")));
  expect(comments.map((entry) => entry.id)).toEqual(["c1"]);
});
