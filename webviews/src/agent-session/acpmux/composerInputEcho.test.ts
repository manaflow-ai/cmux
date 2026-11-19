import { afterEach, describe, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { watchInputEcho } from "./composerInputEcho";

let dom: JSDOM | undefined;
afterEach(() => {
  dom?.window.close();
  dom = undefined;
});

/// A page with a composer whose editor holds `text`, a hand-run frame queue, and a count of reports.
/// `trusted` stands in for `isTrusted`, which a test's events never have: events marked `synthetic`
/// are the page's own.
function page(text = "") {
  dom = new JSDOM(
    `<div class="acpmux-composer-prompt"><div class="acpmux-md-root" contenteditable="true"><p>${text}</p></div></div><input id="other">`,
  );
  const doc = dom.window.document;
  const editor = doc.querySelector(".acpmux-md-root")!;
  const frames: (() => void)[] = [];
  let posts = 0;
  const stop = watchInputEcho(doc, {
    post: () => posts++,
    afterPaint: (run) => frames.push(run),
    trusted: (event) => !(event as Event & { synthetic?: boolean }).synthetic,
  });
  const key = (key: string, init: KeyboardEventInit = {}, target: Element = editor) =>
    target.dispatchEvent(new dom!.window.KeyboardEvent("keydown", { key, bubbles: true, ...init }));
  const input = (inputType: string, target: Element = editor) =>
    target.dispatchEvent(new dom!.window.InputEvent("beforeinput", { inputType, bubbles: true }));
  const type = (text: string) => (editor.querySelector("p")!.textContent += text);
  const paint = () => frames.splice(0).forEach((run) => run());
  return { doc, editor, frames, key, input, type, paint, stop, posts: () => posts };
}

describe("watchInputEcho", () => {
  test("reports the first typed key once, after the frame that drew it", () => {
    const p = page();
    p.key("h");
    p.type("h");
    expect(p.posts()).toBe(0);
    p.paint();
    expect(p.posts()).toBe(1);
    // It has left the document: more typing waits on no frame and reports nothing.
    p.key("i");
    p.type("i");
    p.input("insertText");
    expect(p.frames.length).toBe(0);
    p.paint();
    expect(p.posts()).toBe(1);
  });

  test("an IME's composed text counts", () => {
    const p = page();
    p.input("insertCompositionText");
    p.type("你");
    p.paint();
    expect(p.posts()).toBe(1);
  });

  test("a restored draft, a paste or the page's own event never report", () => {
    const p = page();
    // The page restores a draft: the text changes with no typing event.
    p.type("restored draft");
    p.paint();
    // Command-V and a paste input.
    p.key("v", { metaKey: true });
    p.input("insertFromPaste");
    p.type(" pasted");
    p.paint();
    // An event the page dispatched itself.
    const own = new p.doc.defaultView!.KeyboardEvent("keydown", { key: "x", bubbles: true });
    (own as Event & { synthetic?: boolean }).synthetic = true;
    p.editor.dispatchEvent(own);
    p.type("x");
    p.paint();
    expect(p.posts()).toBe(0);
  });

  test("a key that typed nothing waits for the next one; keys outside the composer are not its", () => {
    const p = page("draft");
    p.key("ArrowLeft");
    p.key("a", {}, p.doc.getElementById("other")!);
    p.paint();
    expect(p.posts()).toBe(0);
    // A character key the editor took for something else (no text change) keeps it waiting.
    p.key("/");
    p.paint();
    expect(p.posts()).toBe(0);
    p.key("k");
    p.type("k");
    p.paint();
    expect(p.posts()).toBe(1);
  });

  test("one frame wait per burst of keys, and the stop leaves before any report", () => {
    const p = page();
    p.key("a");
    p.key("b");
    p.input("insertText");
    expect(p.frames.length).toBe(1);
    p.stop();
    p.type("ab");
    p.paint();
    expect(p.posts()).toBe(0);
  });
});
