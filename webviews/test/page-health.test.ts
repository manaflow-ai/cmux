// The page's half of app health (pages/shared/pageHealth.ts): it beats at once and while visible,
// never while hidden; it counts handled keys and presses; an app without the op stops the beats but
// not the save on hide; it keeps a focused textarea's draft for the reload, per route, and puts it back; it leaves an editor that keeps
// its own draft alone; and the hang injection exists only when the host allowed it.
import { expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import {
  captureState,
  HEALTH_INJECT_NAME,
  HEALTH_INJECT_ALLOWED_NAME,
  installPageHealth,
  PAGE_HEARTBEAT_OP,
  PAGE_SAVE_STATE_OP,
  restoreState,
  markUnsavedEdits,
  UNSAVED_EDITS_ATTRIBUTE,
} from "../src/pages/shared/pageHealth";

type Call = { op: string; params: unknown };

function page(html = "<main></main>", setup?: (window: Record<string, unknown>) => void) {
  const dom = new JSDOM(`<!doctype html><body>${html}</body>`, {
    // jsdom gives a custom scheme an opaque origin with no storage; WebKit does not.
    url: "https://cmux.settings/#/general",
    pretendToBeVisual: true,
  });
  setup?.(dom.window as unknown as Record<string, unknown>);
  const calls: Call[] = [];
  const handlers = new Map<string, (params: unknown) => unknown>();
  let refuse = false;
  const client = {
    call: async <R>(op: string, params: unknown): Promise<R> => {
      calls.push({ op, params });
      if (refuse) throw Object.assign(new Error(op), { code: "cmux.protocol.unknown_op" });
      return null as R;
    },
    handle: (op: string, handler: (params: unknown) => unknown) => {
      handlers.set(op, handler);
      return () => handlers.delete(op);
    },
  };
  let visibility = "visible";
  Object.defineProperty(dom.window.document, "visibilityState", { get: () => visibility });
  const setVisible = (visible: boolean) => {
    visibility = visible ? "visible" : "hidden";
    dom.window.document.dispatchEvent(new dom.window.Event("visibilitychange"));
  };
  return { dom, calls, handlers, client, setVisible, refuse: () => (refuse = true) };
}

const beats = (calls: Call[]) => calls.filter((call) => call.op === PAGE_HEARTBEAT_OP);

test("beats at once while visible, counts handled input, stops while hidden and beats again on show", () => {
  const { dom, calls, client, setVisible } = page();
  installPageHealth(client, dom.window.document);
  expect(beats(calls)).toEqual([{ op: PAGE_HEARTBEAT_OP, params: { handled: 0 } }]);
  dom.window.dispatchEvent(new dom.window.Event("keydown"));
  dom.window.dispatchEvent(new dom.window.Event("pointerdown"));
  setVisible(false);
  setVisible(true);
  expect(beats(calls).at(-1)).toEqual({ op: PAGE_HEARTBEAT_OP, params: { handled: 2 } });
  expect(beats(calls)).toHaveLength(2);
  setVisible(false);
  dom.window.close();
});

test("a hidden page sends no beat", () => {
  const { dom, calls, client, setVisible } = page();
  setVisible(false);
  installPageHealth(client, dom.window.document);
  expect(beats(calls)).toHaveLength(0);
  dom.window.close();
});

test("an app without the op stops the beats for the document", async () => {
  const { dom, calls, client, setVisible, refuse } = page();
  refuse();
  installPageHealth(client, dom.window.document);
  await Promise.resolve();
  await Promise.resolve();
  setVisible(false);
  setVisible(true);
  expect(beats(calls)).toHaveLength(1);
  dom.window.close();
});

test("the host's save keeps a focused draft, and the next load puts it back", () => {
  const first = page(`<textarea id="note" data-cmux-restore-draft></textarea>`);
  installPageHealth(first.client, first.dom.window.document);
  const field = first.dom.window.document.querySelector("textarea")!;
  field.value = "half a thought";
  field.focus();
  expect(first.handlers.get(PAGE_SAVE_STATE_OP)?.({})).toEqual({ saved: true });
  const kept = first.dom.window.sessionStorage.getItem("cmux.page.kept:https://cmux.settings/#/general");
  expect(JSON.parse(kept!).draft).toMatchObject({ path: `[id="note"]`, text: "half a thought" });
  first.setVisible(false);
  first.dom.window.close();

  const second = page(`<textarea id="note" data-cmux-restore-draft></textarea>`);
  restoreState(second.dom.window.document, JSON.parse(kept!));
  expect(second.dom.window.document.querySelector("textarea")!.value).toBe("half a thought");
  second.dom.window.close();
});

test("an edit to a prefilled field comes back over the text the page loaded", () => {
  const html = `<textarea id="note" data-cmux-restore-draft>from the server</textarea>`;
  const first = page(html);
  const field = first.dom.window.document.querySelector("textarea")!;
  field.value = "from the server, edited";
  field.focus();
  const kept = captureState(first.dom.window.document);
  expect(kept.draft).toMatchObject({ text: "from the server, edited", base: "from the server" });
  first.dom.window.close();

  const second = page(html);
  restoreState(second.dom.window.document, kept);
  expect(second.dom.window.document.querySelector("textarea")!.value).toBe("from the server, edited");
  second.dom.window.close();

  // Text the person typed since the load is theirs: the kept edit never replaces it.
  const third = page(html);
  third.dom.window.document.querySelector("textarea")!.value = "typed after the reload";
  restoreState(third.dom.window.document, kept);
  expect(third.dom.window.document.querySelector("textarea")!.value).toBe("typed after the reload");
  third.dom.window.close();
});

test("an edit to a React field, whose default value follows its value, still comes back", () => {
  const html = `<textarea id="note" data-cmux-restore-draft>original</textarea>`;
  const first = page(html);
  installPageHealth(first.client, first.dom.window.document);
  const field = first.dom.window.document.querySelector("textarea")!;
  field.focus();
  field.dispatchEvent(new first.dom.window.InputEvent("beforeinput", { bubbles: true }));
  field.value = "edited";
  // React keeps the default value equal to the value it renders.
  field.defaultValue = "edited";
  const kept = captureState(first.dom.window.document);
  expect(kept.draft).toMatchObject({ text: "edited", base: "original" });
  first.dom.window.close();

  const second = page(html);
  installPageHealth(second.client, second.dom.window.document);
  restoreState(second.dom.window.document, kept);
  const back = second.dom.window.document.querySelector("textarea")!;
  expect(back.value).toBe("edited");
  // The next save keeps the page's own text as the base.
  back.defaultValue = "edited";
  expect(captureState(second.dom.window.document).draft).toMatchObject({ base: "original" });
  second.dom.window.close();
});

test("a page's late prefill is the base, and clearing it is an edit that comes back", () => {
  const first = page(`<textarea id="note" data-cmux-restore-draft></textarea>`);
  installPageHealth(first.client, first.dom.window.document);
  const field = first.dom.window.document.querySelector("textarea")!;
  field.focus();
  // The page fills the field after the focus; the person then clears it.
  field.value = "original";
  field.dispatchEvent(new first.dom.window.InputEvent("beforeinput", { bubbles: true }));
  field.value = "";
  const kept = captureState(first.dom.window.document);
  expect(kept.draft).toMatchObject({ text: "", base: "original" });
  first.dom.window.close();
});

test("a field that did not opt in is never captured or restored (a document editor saves what it is given)", () => {
  const first = page(`<textarea id="source"></textarea>`);
  const field = first.dom.window.document.querySelector("textarea")!;
  field.value = "old text";
  field.focus();
  expect(captureState(first.dom.window.document).draft).toBeUndefined();
  first.dom.window.close();

  // Even a kept draft from an older build is not written into a field that did not opt in.
  const second = page(`<textarea id="source"></textarea>`);
  let inputs = 0;
  second.dom.window.document.querySelector("textarea")!.addEventListener("input", () => (inputs += 1));
  restoreState(second.dom.window.document, { draft: { path: `[id="source"]`, text: "old text" } });
  expect(second.dom.window.document.querySelector("textarea")!.value).toBe("");
  expect(inputs).toBe(0);
  second.dom.window.close();
});

test("an editor that keeps its own draft is left alone", () => {
  const editor = `<div contenteditable="true" tabindex="0" id="composer">hi</div>`;
  const { dom } = page(`<div data-cmux-restore-draft><div class="ProseMirror">${editor}</div></div>`);
  (dom.window.document.getElementById("composer") as HTMLElement).focus();
  expect(captureState(dom.window.document).draft).toBeUndefined();
  dom.window.close();
});

test("a route change at the same place still saves under the new route", () => {
  const { dom, handlers, client } = page(`<textarea id="note" data-cmux-restore-draft></textarea>`);
  installPageHealth(client, dom.window.document);
  const field = dom.window.document.querySelector("textarea")!;
  field.value = "half a thought";
  field.focus();
  handlers.get(PAGE_SAVE_STATE_OP)?.({});
  dom.window.location.hash = "#/other";
  handlers.get(PAGE_SAVE_STATE_OP)?.({});
  const kept = dom.window.sessionStorage.getItem("cmux.page.kept:https://cmux.settings/#/other");
  expect(JSON.parse(kept!).draft).toMatchObject({ text: "half a thought" });
  dom.window.close();
});

test("a page hidden on an app without the beat op still saves its place", async () => {
  const { dom, calls, client, setVisible, refuse } = page(`<textarea id="note" data-cmux-restore-draft></textarea>`);
  refuse();
  installPageHealth(client, dom.window.document);
  await Promise.resolve();
  await Promise.resolve();
  const field = dom.window.document.querySelector("textarea")!;
  field.value = "half a thought";
  field.focus();
  setVisible(false);
  const kept = dom.window.sessionStorage.getItem("cmux.page.kept:https://cmux.settings/#/general");
  expect(JSON.parse(kept!).draft).toMatchObject({ text: "half a thought" });
  setVisible(true);
  expect(beats(calls)).toHaveLength(1);
  dom.window.close();
});

/** A scroller whose content size the test sets, recording what restore writes. */
function scroller(dom: JSDOM, id: string) {
  const element = dom.window.document.getElementById(id)!;
  const size = { height: 0, width: 0 };
  const wrote: { top?: number; left?: number } = {};
  Object.defineProperty(element, "scrollHeight", { get: () => size.height });
  Object.defineProperty(element, "scrollWidth", { get: () => size.width });
  Object.defineProperty(element, "scrollTop", { set: (top: number) => (wrote.top = top), get: () => 0 });
  Object.defineProperty(element, "scrollLeft", { set: (left: number) => (wrote.left = left), get: () => 0 });
  return { size, wrote };
}
/** Animation frames the test runs by hand. */
function frames(dom: JSDOM) {
  const queued: FrameRequestCallback[] = [];
  dom.window.requestAnimationFrame = (callback: FrameRequestCallback) => queued.push(callback);
  return () => queued.splice(0).forEach((callback) => callback(0));
}

test("a kept horizontal place waits for content wide enough to hold it", () => {
  const { dom } = page(`<div id="list"></div>`);
  const list = scroller(dom, "list");
  const frame = frames(dom);
  restoreState(dom.window.document, { scroll: { path: `[id="list"]`, top: 0, left: 200 } });
  expect(list.wrote.left).toBeUndefined();
  list.size.width = 400;
  frame();
  expect(list.wrote.left).toBe(200);
  dom.window.close();
});

test("a navigation during the restore drops the old route's place", () => {
  const { dom } = page(`<div id="list"></div>`);
  const list = scroller(dom, "list");
  const frame = frames(dom);
  let done = false;
  restoreState(dom.window.document, { scroll: { path: `[id="list"]`, top: 300, left: 0 } }, () => (done = true));
  dom.window.location.hash = "#/other";
  list.size.height = 1_000;
  frame();
  expect(list.wrote.top).toBeUndefined();
  expect(done).toBe(true);
  dom.window.close();
});

test("a person who scrolls during the restore keeps their own place", () => {
  const { dom } = page(`<div id="list"></div>`);
  const list = scroller(dom, "list");
  const frame = frames(dom);
  restoreState(dom.window.document, { scroll: { path: `[id="list"]`, top: 300, left: 0 } });
  dom.window.document.dispatchEvent(new dom.window.Event("wheel"));
  list.size.height = 1_000;
  frame();
  expect(list.wrote.top).toBeUndefined();
  dom.window.close();
});

test("the hang injection exists only when the host allowed it", () => {
  const plain = page();
  installPageHealth(plain.client, plain.dom.window.document);
  expect((plain.dom.window as unknown as Record<string, unknown>)[HEALTH_INJECT_NAME]).toBeUndefined();
  plain.setVisible(false);
  plain.dom.window.close();

  const allowed = page("<main></main>", (window) => (window[HEALTH_INJECT_ALLOWED_NAME] = true));
  installPageHealth(allowed.client, allowed.dom.window.document);
  const injected = (allowed.dom.window as unknown as Record<string, unknown>)[HEALTH_INJECT_NAME];
  expect(typeof injected).toBe("function");
  allowed.setVisible(false);
  allowed.dom.window.close();
});

// Codex's review of #39247 at 5e952b6 (F1): the Cloud page's file editor keeps unsaved text only in
// the page, so the page says so with its beat, and at once when an input marks or clears it.
test("reports unsaved edits with the beat, at once after the input that marks them, and clears them", () => {
  // The check after an input runs on the page's next timer turn: the test runs that turn itself.
  const turns: Array<() => void> = [];
  const { dom, calls, client } = page("<textarea></textarea>", (window) => {
    window.setTimeout = (run: () => void) => turns.push(run);
  });
  const input = (field: Element) => {
    field.dispatchEvent(new dom.window.Event("input", { bubbles: true }));
    for (const run of turns.splice(0)) run();
  };
  installPageHealth(client, dom.window.document);
  expect(beats(calls)).toEqual([{ op: PAGE_HEARTBEAT_OP, params: { handled: 0 } }]);
  const field = dom.window.document.querySelector("textarea")!;
  field.setAttribute(UNSAVED_EDITS_ATTRIBUTE, "");
  input(field);
  expect(beats(calls).at(-1)).toEqual({ op: PAGE_HEARTBEAT_OP, params: { handled: 0, edits: true } });
  // Another input with the mark unchanged sends no extra beat.
  input(field);
  expect(beats(calls)).toHaveLength(2);
  field.removeAttribute(UNSAVED_EDITS_ATTRIBUTE);
  input(field);
  expect(beats(calls).at(-1)).toEqual({ op: PAGE_HEARTBEAT_OP, params: { handled: 0 } });
});

// Review of #39247 at aebd2ef: an editor's keymap command (undo, a moved line) changes the text with no
// `input` event, so the store's mark itself beats at once.
test("a store marking unsaved edits beats at once, with no input event", () => {
  const { dom, calls, client } = page();
  installPageHealth(client, dom.window.document);
  markUnsavedEdits(true, dom.window.document);
  expect(beats(calls).at(-1)).toEqual({ op: PAGE_HEARTBEAT_OP, params: { handled: 0, edits: true } });
  markUnsavedEdits(true, dom.window.document);
  expect(beats(calls)).toHaveLength(2);
  markUnsavedEdits(false, dom.window.document);
  expect(beats(calls).at(-1)).toEqual({ op: PAGE_HEARTBEAT_OP, params: { handled: 0 } });
});
