// The stash waits until the chat's own chips were read back (useKeptAttachments' answer), so a
// read still out never sets them over a restored draft's. A chat shown again reads them again, and
// is not ready until that read answers.
import { afterEach, expect, test } from "bun:test";
import { act, useState } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import type { ComposerAttachment } from "../attachments";
import { useKeptAttachments, type KeptAttachments } from "./keptAttachments";

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
});

test("a chat shown again is not ready until its chips are read again", async () => {
  const answers: (() => void)[] = [];
  const store: KeptAttachments = {
    read: () => new Promise((resolve) => answers.push(() => resolve([]))),
    write: async () => ({}),
  };
  let ready = false;
  let show: (session: string) => void = () => {};
  function Probe() {
    const [session, setSession] = useState("chat-a");
    const [chips, setChips] = useState<ComposerAttachment[]>([]);
    show = setSession;
    ready = useKeptAttachments(session, chips, setChips, store, () => false);
    return null;
  }
  root = createRoot(installDom());
  await act(async () => root!.render(<Probe />));
  expect(ready).toBe(false);
  await act(async () => answers.shift()!());
  expect(ready).toBe(true);
  // A, then B, then A again before B's read answers: A is read again, and not ready meanwhile.
  await act(async () => show("chat-b"));
  await act(async () => show("chat-a"));
  expect(ready).toBe(false);
  await act(async () => answers.at(-1)!());
  expect(ready).toBe(true);
});
