// ⌃S while an attachment is still loading (a slow upload, a large paste being read) stashes
// nothing and clears nothing: the attachment's contents are not in the draft yet, and clearing the
// prompt would cancel it, so a stash then would come back without it after a reload.
import { afterEach, expect, test } from "bun:test";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
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
