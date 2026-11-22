// The chat's first-input launch mark posts once per page life, on the frame after the composer drew a
// typed key, and never for a key the prompt did not take, a shortcut or a key outside the composer.
import { afterEach, describe, expect, test } from "bun:test";
import { composerField, resetInputEchoMarkForTests, typesCharacter, watchFirstInputEcho } from "./inputEchoMark";

type Listener = (event: Event) => void;

function keys() {
  const listeners = new Set<Listener>();
  return {
    listeners,
    addEventListener: (_: string, listener: Listener) => listeners.add(listener),
    removeEventListener: (_: string, listener: Listener) => listeners.delete(listener),
    send(event: Partial<KeyboardEvent>) {
      for (const listener of Array.from(listeners)) listener(event as Event);
    },
  };
}

/// An editable prompt inside the composer (or outside it), whose text the test changes.
function field(inComposer = true) {
  const element = {
    isContentEditable: true,
    tagName: "DIV",
    textContent: "",
    closest: (selector: string) => (selector === ".acpmux-composer" ? (inComposer ? {} : null) : element),
  };
  return element;
}

function frames() {
  const queue: (() => void)[] = [];
  return {
    afterPaint: (run: () => void) => queue.push(run),
    paint() {
      for (const run of queue.splice(0)) run();
    },
    get pending() {
      return queue.length;
    },
  };
}

const key = (target: unknown, extra: Partial<KeyboardEvent> = {}) =>
  ({ key: "x", keyCode: 88, isComposing: false, metaKey: false, ctrlKey: false, target, ...extra }) as never;

afterEach(() => resetInputEchoMarkForTests());

describe("inputEchoMark", () => {
  test("posts once, on the frame after the composer drew the typed key, then stops listening", () => {
    const target = keys();
    const paint = frames();
    const prompt = field();
    let posts = 0;
    watchFirstInputEcho({ target, post: () => posts++, afterPaint: paint.afterPaint, trusted: () => true });
    target.send(key(prompt));
    prompt.textContent = "x";
    expect(posts).toBe(0);
    paint.paint();
    expect(posts).toBe(1);
    expect(target.listeners.size).toBe(0);
    target.send(key(prompt));
    prompt.textContent = "xx";
    paint.paint();
    expect(posts).toBe(1);
  });

  test("a key the prompt did not take leaves it armed for the next", () => {
    const target = keys();
    const paint = frames();
    const prompt = field();
    let posts = 0;
    watchFirstInputEcho({ target, post: () => posts++, afterPaint: paint.afterPaint, trusted: () => true });
    target.send(key(prompt));
    paint.paint();
    expect(posts).toBe(0);
    target.send(key(prompt));
    prompt.textContent = "x";
    paint.paint();
    expect(posts).toBe(1);
  });

  test("ignores synthetic keys, shortcuts, input-method keys and keys outside the composer", () => {
    const target = keys();
    const paint = frames();
    const prompt = field();
    const outside = field(false);
    let trusted = false;
    let posts = 0;
    watchFirstInputEcho({ target, post: () => posts++, afterPaint: paint.afterPaint, trusted: () => trusted });
    target.send(key(prompt));
    trusted = true;
    target.send(key(prompt, { metaKey: true }));
    target.send(key(prompt, { isComposing: true }));
    target.send(key(prompt, { key: "Enter" }));
    target.send(key(outside));
    expect(paint.pending).toBe(0);
    expect(posts).toBe(0);
  });

  test("once per page life: a second watch after the post does nothing", () => {
    const target = keys();
    const paint = frames();
    const prompt = field();
    let posts = 0;
    const deps = { target, post: () => posts++, afterPaint: paint.afterPaint, trusted: () => true };
    watchFirstInputEcho(deps);
    watchFirstInputEcho(deps);
    expect(target.listeners.size).toBe(1);
    target.send(key(prompt));
    prompt.textContent = "x";
    paint.paint();
    watchFirstInputEcho(deps);
    expect(target.listeners.size).toBe(0);
    expect(posts).toBe(1);
  });

  test("composerField and typesCharacter", () => {
    expect(composerField(null)).toBeNull();
    expect(composerField(field() as never)).not.toBeNull();
    expect(composerField(field(false) as never)).toBeNull();
    expect(typesCharacter(key(null))).toBe(true);
    expect(typesCharacter(key(null, { key: "ArrowLeft" }))).toBe(false);
    expect(typesCharacter(key(null, { ctrlKey: true }))).toBe(false);
  });
});
