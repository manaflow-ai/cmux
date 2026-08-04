import { afterEach, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { flushSync } from "react-dom";
import { createRoot, type Root } from "react-dom/client";
import { DiffTransportError, type DiffTransport } from "../src/diff/transport";
import type { DiffItem } from "../src/diff-stream";
import { useDiffEditing } from "../src/useDiffEditing";

let dom: JSDOM | null = null;
let root: Root | null = null;
const originalWindow = globalThis.window;
const originalDocument = globalThis.document;
const originalNavigator = globalThis.navigator;

afterEach(async () => {
  if (root) {
    flushSync(() => root?.unmount());
  }
  root = null;
  await new Promise((resolve) => setTimeout(resolve, 0));
  dom?.window.close();
  dom = null;
  (globalThis as any).window = originalWindow;
  (globalThis as any).document = originalDocument;
  (globalThis as any).navigator = originalNavigator;
});

test("diff editing saves the editor draft through the active session", async () => {
  const requests: any[] = [];
  const transport = transportWith(async (command) => {
    requests.push(command);
    if (command.method === "sessionFileLoad") {
      return {
        type: "sessionFileLoaded",
        value: {
          path: "story.txt",
          oldContents: "base\n",
          newContents: "before\n",
        },
      };
    }
    return { type: "sessionFileSaved", value: { path: "story.txt" } };
  });
  const harness = renderEditingHarness(transport);

  harness.editing.beginEditing();
  const files = await harness.editing.loadDiffFiles(harness.item.fileDiff);
  harness.editing.editorOptions.onAttach?.({
    getFile: () => files.newFile,
  } as any, undefined as any);
  harness.editing.onItemEditChange(harness.item, {
    name: "story.txt",
    contents: "after\n",
  });
  harness.state.current.dirtyItemIds = [harness.item.id];
  await harness.editing.saveEdits();

  expect(requests).toEqual([
    {
      method: "sessionFileLoad",
      params: {
        capabilityToken: "0123456789abcdef",
        path: "story.txt",
        sessionId: "01234567-89ab-cdef-0123-456789abcdef",
      },
    },
    {
      method: "sessionFileSave",
      params: {
        capabilityToken: "0123456789abcdef",
        contents: "after\n",
        expectedContents: "before\n",
        path: "story.txt",
        sessionId: "01234567-89ab-cdef-0123-456789abcdef",
      },
    },
  ]);
  const commit = harness.actions.find((action) => action.type === "commit-edit-item");
  expect(commit.fileDiff.additionLines).toContain("after\n");
  expect(harness.actions).toContainEqual({ type: "set-item-dirty", itemId: harness.item.id, dirty: false });
  expect(harness.actions).toContainEqual({ type: "set-edit-mode", enabled: false });
  expect(harness.actions).toContainEqual({ type: "set-edit-feedback", message: "editsSaved" });
  expect(commit.fileDiff.cacheKey).toContain("cmux-edit-01234567-89ab-cdef-0123-456789abcdef");
  expect(harness.item.fileDiff.cacheKey).toBe("story-before");
});

test("diff editing preserves a dirty draft when the worktree changed externally", async () => {
  const transport = transportWith(async (command) => {
    if (command.method === "sessionFileLoad") {
      return {
        type: "sessionFileLoaded",
        value: {
          path: "story.txt",
          oldContents: "base\n",
          newContents: "before\n",
        },
      };
    }
    throw new DiffTransportError("editConflict", "changed externally");
  });
  const harness = renderEditingHarness(transport);

  harness.editing.beginEditing();
  const files = await harness.editing.loadDiffFiles(harness.item.fileDiff);
  harness.editing.editorOptions.onAttach?.({
    getFile: () => files.newFile,
  } as any, undefined as any);
  harness.editing.onItemEditChange(harness.item, {
    name: "story.txt",
    contents: "after\n",
  });
  harness.state.current.dirtyItemIds = [harness.item.id];
  await harness.editing.saveEdits();

  expect(harness.actions).toContainEqual({
    type: "set-edit-feedback",
    message: "editConflict",
    error: true,
  });
  expect(harness.actions).not.toContainEqual({ type: "set-edit-mode", enabled: false });
  expect(harness.actions).not.toContainEqual({ type: "set-item-dirty", itemId: harness.item.id, dirty: false });
});

function renderEditingHarness(transport: DiffTransport) {
  dom = new JSDOM("<!doctype html><html><body><div id='root'></div></body></html>", {
    url: "http://127.0.0.1/diff",
  });
  (globalThis as any).window = dom.window;
  (globalThis as any).document = dom.window.document;
  (globalThis as any).navigator = dom.window.navigator;

  const item = {
    id: "story.txt",
    type: "diff",
    version: 1,
    fileDiff: {
      additionLines: ["before", ""],
      cacheKey: "story-before",
      cmuxDiffMetadataKind: "text",
      deletionLines: ["base", ""],
      hunks: [],
      name: "story.txt",
      type: "modified",
    },
  } as unknown as DiffItem;
  const state = {
    current: {
      dirtyItemIds: [] as string[],
      editMode: false,
      editSaving: false,
      items: [item],
    },
  };
  const session = {
    capabilityToken: "0123456789abcdef",
    sessionId: "01234567-89ab-cdef-0123-456789abcdef",
  };
  const actions: any[] = [];
  let editing!: ReturnType<typeof useDiffEditing>;

  function Harness() {
    editing = useDiffEditing({
      activeSession: session,
      activeSessionRef: { current: session },
      diffStreamComplete: true,
      dispatch: (action) => actions.push(action),
      label: (key) => key,
      latestState: state,
      sessionSource: { kind: "unstaged", repoRoot: "/tmp/repo" },
      state: state.current,
      transport,
    });
    return null;
  }

  root = createRoot(dom.window.document.getElementById("root")!);
  flushSync(() => root?.render(<Harness />));
  return { actions, editing, item, state };
}

function transportWith(request: DiffTransport["request"]): DiffTransport {
  return {
    close() {},
    openResource: () => Promise.reject(new Error("unused")),
    request,
    subscribe: () => () => {},
  };
}
