// ⌃S while an attachment is still loading (a slow upload, a large paste being read) stashes
// nothing and clears nothing: the attachment's contents are not in the draft yet, and clearing the
// prompt would cancel it, so a stash then would come back without it after a reload.
import { afterEach, expect, test } from "bun:test";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import type { ComposerAttachment } from "../attachments";
import { resetStashForTests, type StashTransport } from "./draftStash";
import { useDraftStash } from "./useDraftStash";

let dom: JSDOM | undefined;
let root: Root | undefined;
const scope = globalThis as Record<string, unknown>;
const saved = new Map<string, unknown>();

function installDom(): HTMLElement {
  dom = new JSDOM("<!doctype html><html><body><main id=root></main></body></html>", { url: "http://localhost/" });
  for (const key of ["window", "document", "navigator", "IS_REACT_ACT_ENVIRONMENT"]) saved.set(key, scope[key]);
  Object.assign(scope, {
    window: dom.window,
    document: dom.window.document,
    navigator: dom.window.navigator,
    IS_REACT_ACT_ENVIRONMENT: true,
  });
  return dom.window.document.getElementById("root")!;
}

afterEach(async () => {
  if (root) await act(async () => root!.unmount());
  root = undefined;
  dom?.window.close();
  dom = undefined;
  for (const [key, value] of saved) {
    if (value === undefined) delete scope[key];
    else scope[key] = value;
  }
  saved.clear();
  resetStashForTests();
});

test("⌃S while an attachment loads stashes nothing and keeps the prompt", async () => {
  const pushed: string[] = [];
  const transport: StashTransport = {
    list: async () => ({ drafts: [] }),
    push: async (chat, text) => {
      pushed.push(text);
      return { draft: { id: "stash-1", text, attachments: [], at: 1 } };
    },
    get: async () => ({}),
    drop: async () => ({ removed: true }),
    move: async () => ({ moved: 0, ids: [] }),
  };
  resetStashForTests(transport);
  let loading = true;
  let cleared = 0;
  let toggle: () => void = () => {};
  function Probe() {
    toggle = useDraftStash("chat", {
      held: () => ({ text: "a draft with an image on its way", attachments: [] }),
      loading: () => loading,
      clear: () => void (cleared += 1),
      restore: () => {},
      focus: () => {},
    }).toggle;
    return null;
  }
  root = createRoot(installDom());
  await act(async () => root!.render(<Probe />));
  await act(async () => toggle());
  expect(pushed).toEqual([]);
  expect(cleared).toBe(0);
  // Loaded: ⌃S stashes it and empties the prompt.
  loading = false;
  await act(async () => toggle());
  expect(pushed).toEqual(["a draft with an image on its way"]);
  expect(cleared).toBe(1);
});

test("a pick while the prompt is not ready restores nothing and keeps the stashed copy", async () => {
  const dropped: string[] = [];
  const restored: string[] = [];
  const transport: StashTransport = {
    list: async () => ({ drafts: [{ id: "stash-1", text: "kept", attachments: [], at: 1 }] }),
    push: async () => ({}),
    get: async () => ({ draft: { id: "stash-1", text: "kept", attachments: [], at: 1 } }),
    drop: async (_chat, id) => (dropped.push(id), { removed: true }),
    move: async () => ({ moved: 0, ids: [] }),
  };
  resetStashForTests(transport);
  let unstash: (id?: string) => void = () => {};
  function Probe() {
    unstash = useDraftStash("chat", {
      held: () => ({ text: "", attachments: [] }),
      loading: () => true,
      clear: () => {},
      restore: (text) => void restored.push(text),
      focus: () => {},
    }).unstash;
    return null;
  }
  root = createRoot(installDom());
  await act(async () => root!.render(<Probe />));
  await act(async () => unstash("stash-1"));
  expect(restored).toEqual([]);
  expect(dropped).toEqual([]);
});

test("a chip that changed while the stash was out (same id) keeps the prompt", async () => {
  let land: () => void = () => {};
  const transport: StashTransport = {
    list: async () => ({ drafts: [] }),
    push: (_chat, text) =>
      new Promise((resolve) => (land = () => resolve({ draft: { id: "stash-1", text, attachments: [], at: 1 } }))),
    get: async () => ({}),
    drop: async () => ({ removed: true }),
    move: async () => ({ moved: 0, ids: [] }),
  };
  resetStashForTests(transport);
  const preview = { id: "img", kind: "image", name: "a.png", mimeType: "image/png", size: 3 } as const;
  let chips: ComposerAttachment[] = [preview];
  let cleared = 0;
  let toggle: () => void = () => {};
  function Probe() {
    toggle = useDraftStash("chat", {
      held: () => ({ text: "with an image", attachments: chips }),
      loading: () => false,
      clear: () => void (cleared += 1),
      restore: () => {},
      focus: () => {},
    }).toggle;
    return null;
  }
  root = createRoot(installDom());
  await act(async () => root!.render(<Probe />));
  await act(async () => toggle());
  // The original's upload retried and landed: the same chip, now with its path.
  chips = [{ ...preview, originalPath: "/tmp/a.png" } as ComposerAttachment];
  await act(async () => land());
  expect(cleared).toBe(0);
});

test("⌃S while a restore's drop is out waits, so a full stack lets no other draft go", async () => {
  const pushed: string[] = [];
  let dropDone: () => void = () => {};
  const transport: StashTransport = {
    list: async () => ({ drafts: [{ id: "stash-1", text: "kept", attachments: [], at: 1 }] }),
    push: async (_chat, text) => (pushed.push(text), { draft: { id: "stash-2", text, attachments: [], at: 2 } }),
    get: async () => ({ draft: { id: "stash-1", text: "kept", attachments: [], at: 1 } }),
    drop: () => new Promise((resolve) => (dropDone = () => resolve({ removed: true }))),
    move: async () => ({ moved: 0, ids: [] }),
  };
  resetStashForTests(transport);
  let text = "";
  let api: { unstash: (id?: string) => void; toggle: () => void } = { unstash: () => {}, toggle: () => {} };
  function Probe() {
    api = useDraftStash("chat", {
      held: () => ({ text, attachments: [] }),
      loading: () => false,
      clear: () => void (text = ""),
      restore: (back) => void (text = back),
      focus: () => {},
    });
    return null;
  }
  globalThis.requestAnimationFrame ??= (done: FrameRequestCallback) => {
    setTimeout(() => done(0), 0);
    return 0;
  };
  root = createRoot(installDom());
  await act(async () => root!.render(<Probe />));
  await act(async () => api.unstash("stash-1"));
  for (let turn = 0; turn < 5; turn++) await act(async () => new Promise((resolve) => setTimeout(resolve, 0)));
  expect(text).toBe("kept");
  // The drop is still out: ⌃S stashes nothing yet.
  await act(async () => api.toggle());
  expect(pushed).toEqual([]);
  await act(async () => dropDone());
  await act(async () => api.toggle());
  expect(pushed).toEqual(["kept"]);
});

test("a session's composer lists the tab's leftover drafts after its own, and a pick takes one from the tab", async () => {
  const rows = new Map([
    ["session-b", [{ id: "b-1", text: "b's own", attachments: [], at: 2 }]],
    ["new-tab:t", [{ id: "left-1", text: "left behind", attachments: [], at: 1 }]],
  ]);
  const dropped: string[] = [];
  const restored: string[] = [];
  const transport: StashTransport = {
    list: async (chat) => ({ drafts: rows.get(chat) ?? [] }),
    push: async () => ({}),
    get: async (chat, id) => ({ draft: rows.get(chat)?.find((row) => row.id === id) }),
    drop: async (chat, id) => (dropped.push(`${chat}/${id}`), { removed: true }),
    move: async () => ({ moved: 0, ids: [] }),
  };
  resetStashForTests(transport);
  let stash: ReturnType<typeof useDraftStash> | undefined;
  function Probe() {
    stash = useDraftStash(
      "session-b",
      {
        held: () => ({ text: "", attachments: [] }),
        loading: () => false,
        clear: () => {},
        restore: (text) => void restored.push(text),
        focus: () => {},
      },
      "new-tab:t",
    );
    return null;
  }
  root = createRoot(installDom());
  await act(async () => root!.render(<Probe />));
  await act(async () => {});
  expect(stash!.stashed.map((draft) => draft.text)).toEqual(["b's own", "left behind"]);
  await act(async () => stash!.unstash("left-1"));
  await act(async () => new Promise((resolve) => setTimeout(resolve, 30)));
  expect(restored).toEqual(["left behind"]);
  expect(dropped).toEqual(["new-tab:t/left-1"]);
});
