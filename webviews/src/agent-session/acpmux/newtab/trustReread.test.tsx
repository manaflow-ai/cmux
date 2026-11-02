import { afterEach, beforeEach, expect, test } from "bun:test";
import { act, useState } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import type { TrustSource } from "../folderTrust";
import { useFolderTrustAsk } from "../useFolderTrustAsk";

// SHORTCUT FRAMES F2 (review of #31624): a parked New Tab spare drew the tab's folder before Cmd-T, but its trust
// read was refused (the parked page has no tab's roots). Cmd-T then keeps the screen mounted (same folder), so
// nothing read the folder again and the "Trust <folder>?" card never came before the first send. Each adoption
// bumps `reread`, which reads the folder again.

let dom: JSDOM | undefined;
let root: Root | undefined;
const scope = globalThis as Record<string, unknown>;
const saved = new Map<string, unknown>();

beforeEach(() => {
  dom = new JSDOM("<!doctype html><html><body><main id=root></main></body></html>", { url: "http://localhost/" });
  for (const key of ["window", "document", "localStorage", "IS_REACT_ACT_ENVIRONMENT"]) saved.set(key, scope[key]);
  Object.assign(scope, {
    window: dom.window,
    document: dom.window.document,
    localStorage: dom.window.localStorage,
    IS_REACT_ACT_ENVIRONMENT: true,
  });
  root = createRoot(dom.window.document.getElementById("root")!);
});

afterEach(() => {
  act(() => root?.unmount());
  for (const [key, value] of saved) {
    if (value === undefined) delete scope[key];
    else scope[key] = value;
  }
  saved.clear();
  dom?.window.close();
});

test("a kept New Tab adoption reads the folder's trust again", async () => {
  let refuse = true;
  let reads = 0;
  const source: TrustSource = {
    get: async (cwd: string) => {
      reads += 1;
      if (refuse) throw new Error("path outside roots");
      return { cwd, level: "unknown" };
    },
    set: async () => ({}),
  };
  const view: { ask?: unknown; adopt?: () => void } = {};
  function Probe() {
    const [adoptions, setAdoptions] = useState(0);
    const trust = useFolderTrustAsk(source, {
      cwd: "/work/never-trusted",
      family: "claude",
      prompts: 0,
      authority: "local",
      visit: "visit-1",
      reread: adoptions,
    });
    view.ask = trust.ask;
    view.adopt = () => setAdoptions((count) => count + 1);
    return null;
  }
  await act(async () => root!.render(<Probe />));
  await act(async () => new Promise((resolve) => setTimeout(resolve, 20)));
  expect(view.ask).toBeUndefined();
  const before = reads;
  // Cmd-T adopted the page: the tab's roots now allow the read.
  refuse = false;
  await act(async () => view.adopt!());
  await act(async () => new Promise((resolve) => setTimeout(resolve, 20)));
  expect(reads).toBeGreaterThan(before);
  expect((view.ask as { state?: string } | undefined)?.state).toBe("ask");
});
