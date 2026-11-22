// Home Channels' composer draws its field before the editor's chunk arrives (LazyPromptEditor.tsx).
// Its wait must not lose, double or misplace a key, and must take nothing that is not its own: a
// shortcut, a key on the page (Home Channels' j/k/r/t/c/e) or another field's typing goes on as
// before. The chunk is held back here (holdPromptEditorForTests) so keys land in the wait, then let
// through; the real composer and editor run in a DOM, keys go where the keyboard is, as WebKit sends.
import { afterAll, afterEach, beforeAll, expect, test } from "bun:test";
import { settleReact } from "./support/domTeardown";
import { act } from "react";
import { createRoot } from "react-dom/client";
import { JSDOM } from "jsdom";

const dom = new JSDOM("<!doctype html><html><body><main id=root></main><input id=other></body></html>", {
  url: "http://localhost/",
  pretendToBeVisual: true,
});
Object.assign(dom.window, {
  ResizeObserver: class {
    observe() {}
    unobserve() {}
    disconnect() {}
  },
});
// A DOM with no layout: the editor's scroll into view measures empty rectangles.
const emptyRect = () => ({ top: 0, bottom: 0, left: 0, right: 0, width: 0, height: 0, x: 0, y: 0, toJSON() {} });
Object.assign(dom.window.Range.prototype, {
  getClientRects: () => Object.assign([], { item: () => null }),
  getBoundingClientRect: emptyRect,
});
Object.defineProperty(dom.window.navigator, "platform", { configurable: true, value: "MacIntel" });
const scope = globalThis as Record<string, unknown>;
const keys = [
  "window",
  "document",
  "navigator",
  "HTMLElement",
  "Element",
  "Node",
  "File",
  "FileReader",
  "MouseEvent",
  "KeyboardEvent",
  "InputEvent",
  "getComputedStyle",
  "requestAnimationFrame",
  "cancelAnimationFrame",
  "IS_REACT_ACT_ENVIRONMENT",
];
const saved = new Map(keys.map((key) => [key, scope[key]]));
Object.assign(scope, {
  window: dom.window,
  document: dom.window.document,
  navigator: dom.window.navigator,
  HTMLElement: dom.window.HTMLElement,
  Element: dom.window.Element,
  Node: dom.window.Node,
  File: dom.window.File,
  FileReader: dom.window.FileReader,
  MouseEvent: dom.window.MouseEvent,
  KeyboardEvent: dom.window.KeyboardEvent,
  InputEvent: dom.window.InputEvent,
  getComputedStyle: dom.window.getComputedStyle.bind(dom.window),
  requestAnimationFrame: (run: (time: number) => void) => setTimeout(() => run(0), 0),
  cancelAnimationFrame: (id: number) => clearTimeout(id),
  IS_REACT_ACT_ENVIRONMENT: true,
});

const { Composer } = await import("../src/pages/home-channels/Composer");
const { createStrings } = await import("../src/pages/shared/i18n");
const { holdPromptEditorForTests } = await import("../src/agent-session/acpmux/composer/LazyPromptEditor");
const { focusRoute } = await import("../src/ui/focusRoute");
const editorChunk = await import("../src/agent-session/acpmux/composer/PromptEditor");
const table = (await import("../src/pages/home-channels/generated/strings.json")).default;
type MarkdownFieldElement = import("../src/agent-session/acpmux/MarkdownField").MarkdownFieldElement;

const strings = createStrings(table, ["en"]);
const doc = dom.window.document;
const other = doc.getElementById("other") as HTMLInputElement;

// The window's capture listeners for keydown and pointerdown, as they are added and removed: the
// wait's own are the ones added while it starts.
type Listener = { type: string; listener: EventListenerOrEventListenerObject };
const live: Listener[] = [];
const capture = (options: boolean | AddEventListenerOptions | undefined) =>
  typeof options === "boolean" ? options : options?.capture === true;
const add = dom.window.addEventListener.bind(dom.window);
const remove = dom.window.removeEventListener.bind(dom.window);
dom.window.addEventListener = ((type: string, listener: EventListenerOrEventListenerObject, options?: boolean) => {
  if ((type === "keydown" || type === "pointerdown") && capture(options)) live.push({ type, listener });
  add(type, listener, options);
}) as typeof dom.window.addEventListener;
dom.window.removeEventListener = ((type: string, listener: EventListenerOrEventListenerObject, options?: boolean) => {
  if (capture(options)) {
    const at = live.findIndex((entry) => entry.type === type && entry.listener === listener);
    if (at >= 0) live.splice(at, 1);
  }
  remove(type, listener, options);
}) as typeof dom.window.removeEventListener;
// The focus route's own window listener, added once for good, before any wait starts.
focusRoute(other, "system", "test: the focus route watches this window");
other.blur();

const restores: (() => void)[] = [];
afterEach(() => {
  for (const restore of restores.splice(0).reverse()) restore();
});
afterAll(async () => {
  await settleReact();
  dom.window.addEventListener = add;
  dom.window.removeEventListener = remove;
  for (const [key, value] of saved) {
    if (value === undefined) delete scope[key];
    else scope[key] = value;
  }
  dom.window.close();
});

// The composer's first mount adds window listeners of its own, once for the window: they are made
// here, so a test counts only the wait's.
beforeAll(async () => {
  const composer = await mount();
  await composer.unmount();
  for (const restore of restores.splice(0)) restore();
});

async function settle() {
  for (let turn = 0; turn < 5; turn++) await act(async () => new Promise((resolve) => setTimeout(resolve, 0)));
}

/** The editor's chunk, held back until `release`. */
function holdChunk() {
  let release!: () => void;
  const arrived = new Promise<typeof editorChunk>((resolve) => {
    release = () => resolve(editorChunk);
  });
  restores.push(holdPromptEditorForTests(() => arrived));
  return {
    async release() {
      release();
      await settle();
      await settle();
    },
  };
}

/** The composer, its editor's chunk held; `focusOnOpen` asks focus on mount (the edit composer). */
async function mount({ focusOnOpen = false } = {}) {
  const chunk = holdChunk();
  const container = doc.getElementById("root")!;
  const root = createRoot(container);
  const before = live.length;
  await act(async () => {
    root.render(
      <Composer
        strings={strings}
        placeholder="Message"
        label="Message"
        onSend={async () => true}
        focusOnOpen={focusOnOpen}
      />,
    );
  });
  await settle();
  const box = () => container.querySelector<HTMLElement>(".hc-composer-field[data-prompt-waiting]");
  const field = () => {
    const found = [...container.querySelectorAll<MarkdownFieldElement>("*")].find((node) => node.acpmuxMarkdownField);
    if (!found) throw new Error("no prompt editor");
    return found.acpmuxMarkdownField!;
  };
  const editable = () => container.querySelector<HTMLElement>('[contenteditable="true"]');
  return {
    chunk,
    box,
    field,
    editable,
    /** The wait's own window listeners (added since mount), by type. */
    waitListeners: () =>
      live
        .slice(before)
        .map((entry) => entry.type)
        .sort(),
    /** A key-down where the keyboard is; answers the event (its defaultPrevented). */
    async key(key: string, init: KeyboardEventInit = {}) {
      const event = new dom.window.KeyboardEvent("keydown", { key, bubbles: true, cancelable: true, ...init });
      await act(async () => {
        (doc.activeElement ?? doc.body).dispatchEvent(event);
      });
      return event;
    },
    async type(text: string) {
      for (const key of text) expect((await this.key(key)).defaultPrevented).toBe(true);
    },
    unmount: () => act(async () => root.unmount()),
  };
}

test("keys typed after an early focus, before the chunk, land in the editor in order, once, caret after", async () => {
  const composer = await mount({ focusOnOpen: true });
  expect(composer.box()).not.toBeNull();
  expect(doc.activeElement).toBe(composer.box());
  expect(composer.waitListeners()).toEqual(["keydown", "pointerdown"]);
  await composer.type("hey");
  await composer.chunk.release();
  expect(composer.box()).toBeNull();
  expect(composer.field().value()).toBe("hey");
  const { value, selectionStart, selectionEnd } = composer.field().text();
  expect(value).toBe("hey");
  expect([selectionStart, selectionEnd]).toEqual([3, 3]);
  expect(composer.editable()?.contains(doc.activeElement)).toBe(true);
  // The wait's listeners are gone once the editor is ready.
  expect(composer.waitListeners()).toEqual([]);
  await composer.unmount();
});

test("Backspace in the wait removes one character as a person counts them", async () => {
  const composer = await mount({ focusOnOpen: true });
  await composer.type("a");
  expect((await composer.key("👨‍👩‍👧")).defaultPrevented).toBe(true);
  expect((await composer.key("Backspace")).defaultPrevented).toBe(true);
  await composer.chunk.release();
  expect(composer.field().value()).toBe("a");
  await composer.unmount();
});

test("a shortcut, a key on the page and another field's typing are neither taken nor kept", async () => {
  const composer = await mount({ focusOnOpen: true });
  await composer.type("x");
  for (const modifier of ["metaKey", "ctrlKey", "altKey"] as const)
    expect((await composer.key("k", { [modifier]: true })).defaultPrevented).toBe(false);
  // The keyboard back on the page (the box gave it up): Home Channels' plain-key shortcuts work.
  await act(async () => composer.box()!.blur());
  expect(doc.activeElement).toBe(doc.body);
  for (const key of ["j", "k", "r", "Backspace"]) expect((await composer.key(key)).defaultPrevented).toBe(false);
  // Another field takes the keyboard: its typing is its own, and the wait ends.
  await act(async () => composer.box()!.focus());
  await act(async () => other.focus());
  expect(composer.waitListeners()).toEqual([]);
  for (const key of ["o", "Backspace"]) expect((await composer.key(key)).defaultPrevented).toBe(false);
  await composer.chunk.release();
  expect(composer.field().value()).toBe("x");
  // The editor did not take the keyboard back from the other field.
  expect(doc.activeElement).toBe(other);
  other.blur();
  await composer.unmount();
});

test("a press outside the field ends the wait and removes both window listeners", async () => {
  const composer = await mount({ focusOnOpen: true });
  await composer.type("q");
  expect(composer.waitListeners()).toEqual(["keydown", "pointerdown"]);
  await act(async () => {
    doc.body.dispatchEvent(new dom.window.MouseEvent("pointerdown", { bubbles: true }));
  });
  expect(composer.waitListeners()).toEqual([]);
  expect((await composer.key("z")).defaultPrevented).toBe(false);
  await composer.chunk.release();
  expect(composer.field().value()).toBe("q");
  await composer.unmount();
});

test("a press or focus on the waiting field starts the wait; unmounting before ready removes its listeners", async () => {
  const composer = await mount();
  expect(composer.waitListeners()).toEqual([]);
  await act(async () => composer.box()!.focus());
  expect(composer.waitListeners()).toEqual(["keydown", "pointerdown"]);
  await composer.type("w");
  await composer.unmount();
  expect(composer.waitListeners()).toEqual([]);
});

test("text an input method composes in the wait is not kept (the box is no text field)", async () => {
  const composer = await mount({ focusOnOpen: true });
  const target = doc.activeElement!;
  await act(async () => {
    target.dispatchEvent(new dom.window.CompositionEvent("compositionstart", { bubbles: true }));
  });
  for (const key of ["Process", "n"])
    expect((await composer.key(key, { isComposing: true, keyCode: 229 })).defaultPrevented).toBe(false);
  await act(async () => {
    target.dispatchEvent(new dom.window.CompositionEvent("compositionend", { bubbles: true, data: "に" }));
  });
  await composer.chunk.release();
  // Lost: the eager editor would have taken the composition. The wait is the chunk's fetch after
  // the first press, before the page's idle fetch (at most 500 ms after its first frame).
  expect(composer.field().value()).toBe("");
  expect(composer.editable()?.contains(doc.activeElement)).toBe(true);
  await composer.unmount();
});
