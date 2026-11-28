// Chat multiplayer (Leo 2026-10-26: "we can still do the regular chat multiplayer"): the pane tells
// a shared chat's other people it types only when the person edits the prompt. A value applied
// from outside is not typing: a chat's draft coming back (read from the daemon on open, with the
// field's own normalizing, or the remount cache on a switch), or a failed prompt restored. Every
// clear says it stopped.
import { afterAll, afterEach, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act, createRef } from "react";
import type { Root } from "react-dom/client";
import type { MarkdownFieldElement } from "../src/agent-session/acpmux/MarkdownField";
import type { ComposerHandle } from "../src/agent-session/acpmux/Composer";
import { teardownDom } from "./support/domTeardown";
import { importWithDom } from "./support/importWithDom";

const { noChat } = await importWithDom(() => import("../src/gallery/fixtures/acpmux"));
const { writePersistedDraft } = await importWithDom(() => import("../src/agent-session/acpmux/composerDraft"));

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
  // jsdom lays nothing out and its Range has no rects: ProseMirror measures one to scroll a paste
  // into view (a chip's text going back into the prompt goes in as a paste). An empty box will do.
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
  // A saved draft (composerDraft.ts, the page's localStorage remount cache) would come back in
  // the next test's prompt. These tests open chats of their own: the module's pending draft
  // writes outlive a test file.
  dom.window.localStorage.clear();
});

afterAll(async () => {
  await teardownDom(saved, { window: dom.window, scope });
});

function Chips() {
  return null;
}

/// The chat each report named: the composer's own, never the next chat's during a switch.
const typedIn: Array<string | undefined> = [];

async function render(sessionId: string, typed: string[], handle = createRef<ComposerHandle>()) {
  const { createRoot } = await import("react-dom/client");
  const { Composer } = await import("../src/agent-session/acpmux/Composer");
  const snapshot = noChat([], {
    sessionId,
    summary: { sessionId, harness: "claude", cwd: "/Users/you/src/app", turnCount: 0 },
  });
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
        onTyping={(text, id) => {
          typed.push(text);
          typedIn.push(id);
        }}
        handle={handle}
        localName="studio"
        projectChoices={[{ cwd: "/Users/you/src/app", label: "app" }]}
      />,
    ),
  );
  await until(() => !!host.querySelector('[role="combobox"]'), "the editor");
  return handle;
}

async function until(ready: () => boolean, what: string) {
  const deadline = performance.now() + 2_000;
  while (!ready()) {
    if (performance.now() > deadline) throw new Error(`timed out waiting for ${what}`);
    await settle();
  }
}

const settle = () =>
  act(async () => {
    await new Promise((resolve) => setTimeout(resolve, 0));
  });

const prompt = () => host.querySelector('[role="combobox"]')?.textContent ?? "";
const markdownField = () => host.querySelector<MarkdownFieldElement>(".acpmux-md-field")!.acpmuxMarkdownField!;
const page = () =>
  dom.window as unknown as { cmuxAcpmuxActions?: Record<string, (params: unknown) => Promise<unknown>> };


test("typing profile (scratch)", async () => {
  const typed: string[] = [];
  await render("typing-prof", typed);
  await act(async () => markdownField().insertTyped("Here is a draft prompt with some words in it. "));
  await settle();
  const times: number[] = [];
  const reads = new Map<string, number>();
  let counting = false;
  const W = dom.window as any;
  const note = (name: string) => {
    if (!counting) return;
    const st = (new Error().stack ?? "").split("\n").slice(2, 9).map((l) => l.trim().replace(/\(.*\/(src|node_modules)\//, "(").slice(0, 90)).join(" < ");
    const k = name + " @ " + st;
    reads.set(k, (reads.get(k) ?? 0) + 1);
  };
  for (const [proto, names] of [
    [W.Element.prototype, ["getBoundingClientRect", "getClientRects", "scrollIntoView"]],
    [W.Range.prototype, ["getBoundingClientRect", "getClientRects"]],
    [W.Document.prototype, ["elementFromPoint", "caretRangeFromPoint"]],
    [W.Selection.prototype, ["getRangeAt", "collapse", "addRange", "removeAllRanges", "setBaseAndExtent", "extend"]],
  ] as const) for (const n of names) { const f = proto[n]; if (f) proto[n] = function (this: unknown, ...a: unknown[]) { note(n); return f.apply(this, a); }; }
  for (const [proto, names] of [[W.HTMLElement.prototype, ["offsetHeight", "offsetWidth", "offsetTop", "offsetLeft", "offsetParent"]], [W.Element.prototype, ["scrollHeight", "scrollTop", "clientHeight", "clientWidth", "scrollWidth"]]] as const)
    for (const n of names) { const d = Object.getOwnPropertyDescriptor(proto, n); if (d?.get) Object.defineProperty(proto, n, { ...d, get() { note(n); return d.get!.call(this); } }); }
  const gcs = W.getComputedStyle; W.getComputedStyle = (...a: unknown[]) => { note("getComputedStyle"); return gcs.apply(W, a); };
  (globalThis as any).getComputedStyle = W.getComputedStyle;
  const text = "the quick brown fox jumps over the lazy dog ";
  for (let i = 0; i < 400; i++) {
    const ch = text[i % text.length]!;
    if (i === 50) { (globalThis as any).__prof = {}; counting = true; }
    const t0 = performance.now();
    markdownField().insertTyped(ch);
    await Promise.resolve();
    times.push(performance.now() - t0);
    const was = counting; counting = false;
    if (i % 20 === 19) await settle();
    counting = was;
  }
  console.log("PROF stages ms/key", JSON.stringify(Object.fromEntries(Object.entries((globalThis as any).__prof as Record<string, number>).map(([k, v]) => [k, +(v / 350).toFixed(3)]))));
  console.log("PROF slow", times.map((v, i) => [i, text[i % text.length], +v.toFixed(2)]).filter((x) => (x[2] as number) > 0.8).slice(0, 30).map((x) => x.join(":")).join(" "));
  for (const [k, v] of [...reads].sort((a, b) => b[1] - a[1]).slice(0, 15)) console.log("PROF read", (v / 350).toFixed(2), "/key", k);
  const s = times.slice(50).sort((a, b) => a - b);
  console.log("PROF p50", s[Math.floor(s.length * 0.5)]!.toFixed(3), "p95", s[Math.floor(s.length * 0.95)]!.toFixed(3), "mean", (s.reduce((a, b) => a + b, 0) / s.length).toFixed(3));
});
