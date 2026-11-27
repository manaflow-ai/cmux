// The copy's prompt takes clicks and typing before the live composer is up, and hands what it holds to the
// live prompt (Leo, 2026-11-22: "a composer that's TECHNICALLY not wholly interactive as in it'd send data but
// you can click around on it and type in it, that's enough").
import { expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { COMPOSER_READY_EVENT } from "../composerFocus";
import { handOverSkeleton } from "./live";
import { SNAPSHOT_SKELETON_ATTRIBUTE } from "./shared";
import { copyPrompt, drawSkeleton, skeletonField } from "./skeleton";

const PROMPT = (inner: string, cls = "acpmux-composer-prompt") =>
  `<div class="${cls}"><div class="acpmux-md-field"><span class="acpmux-md-placeholder">Ask anything</span>` +
  `<div class="acpmux-md-root">${inner}</div></div></div>`;

function page(copyMarkup: string, liveMarkup = "") {
  const win = new JSDOM(
    `<!doctype html><body><div id="root">${liveMarkup}</div><cmux-chat-snapshot></cmux-chat-snapshot></body>`,
    { url: "http://localhost/" },
  ).window as unknown as Window & typeof globalThis;
  const doc = win.document;
  // The copy lives in the snapshot host's shadow root, as paint.ts draws it: the page's selectors never find it.
  const shadow = doc.querySelector("cmux-chat-snapshot")!.attachShadow({ mode: "open" });
  shadow.innerHTML = `<div id="copy">${copyMarkup}</div>`;
  // JSDOM lays nothing out: the copy's prompt gets a box.
  win.HTMLElement.prototype.getBoundingClientRect = function () {
    return { left: 10, top: 500, width: 600, height: 48, right: 610, bottom: 548, x: 10, y: 500 } as DOMRect;
  };
  const typed: string[] = [];
  doc.execCommand = ((command: string, _ui: boolean, value?: string) => {
    if (command !== "insertText" || !value) return false;
    typed.push(value);
    (doc.activeElement as HTMLElement).textContent += value;
    return true;
  }) as typeof doc.execCommand;
  return { win, doc, copy: shadow.getElementById("copy")!, typed };
}

const EDITABLE = '<div contenteditable="true" class="ProseMirror"><p><br></p></div>';

test("an empty prompt in the copy gets a field that takes focus and holds Enter", () => {
  const { doc, copy } = page(PROMPT(EDITABLE));
  const prompt = copyPrompt(copy);
  expect(prompt?.getAttribute("contenteditable")).toBe("true");
  const field = drawSkeleton(doc, copy, prompt!)!;
  expect(field.hasAttribute(SNAPSHOT_SKELETON_ATTRIBUTE)).toBe(true);
  expect(field.parentElement).toBe(doc.body);
  expect(doc.getElementById("root")!.contains(field)).toBe(false);
  expect(doc.activeElement).toBe(field);
  expect(field.style.left).toBe("10px");
  expect(field.style.top).toBe("500px");
  const enter = new doc.defaultView!.KeyboardEvent("keydown", { key: "Enter", cancelable: true });
  field.dispatchEvent(enter);
  expect(enter.defaultPrevented).toBe(true);
  const line = new doc.defaultView!.KeyboardEvent("keydown", { key: "Enter", shiftKey: true, cancelable: true });
  field.dispatchEvent(line);
  expect(line.defaultPrevented).toBe(false);
});

test("typing hides the copy's placeholder", () => {
  const { doc, copy } = page(PROMPT(EDITABLE));
  const field = drawSkeleton(doc, copy, copyPrompt(copy)!)!;
  field.textContent = "hi";
  field.dispatchEvent(new doc.defaultView!.Event("input"));
  expect(copy.querySelector<HTMLElement>(".acpmux-md-placeholder")!.style.visibility).toBe("hidden");
});

test("no field over a draft, a hidden prompt or a copy with no prompt", () => {
  expect(copyPrompt(page(PROMPT('<div contenteditable="true"><p>draft</p></div>')).copy)).toBeUndefined();
  expect(copyPrompt(page(PROMPT(EDITABLE, "acpmux-composer-prompt is-hidden")).copy)).toBeUndefined();
  expect(copyPrompt(page("<p>no composer</p>").copy)).toBeUndefined();
});

test("focus does not move off an element that already has it", () => {
  const { doc, copy } = page(PROMPT(EDITABLE), '<input id="other">');
  doc.getElementById("other")!.focus();
  drawSkeleton(doc, copy, copyPrompt(copy)!);
  expect(doc.activeElement?.id).toBe("other");
});

test("the text goes into the live prompt at once when its editor is up", () => {
  const { doc, copy, typed } = page(PROMPT(EDITABLE), PROMPT(EDITABLE));
  const field = drawSkeleton(doc, copy, copyPrompt(copy)!)!;
  field.textContent = "fix the build";
  handOverSkeleton(doc);
  expect(skeletonField(doc)).toBeNull();
  expect(typed).toEqual(["fix the build"]);
  expect(doc.activeElement).toBe(doc.querySelector("#root [contenteditable='true']"));
});

test("the field waits over the live prompt until its editor is up, then hands over", () => {
  const { win, doc, copy, typed } = page(PROMPT(EDITABLE), PROMPT(""));
  const field = drawSkeleton(doc, copy, copyPrompt(copy)!)!;
  field.textContent = "hello";
  handOverSkeleton(doc);
  expect(skeletonField(doc)).toBe(field);
  const livePlaceholder = doc.querySelector<HTMLElement>("#root .acpmux-md-placeholder")!;
  expect(livePlaceholder.style.visibility).toBe("hidden");
  // The editor comes up.
  doc.querySelector("#root .acpmux-md-root")!.innerHTML = EDITABLE;
  win.dispatchEvent(new win.Event(COMPOSER_READY_EVENT));
  expect(skeletonField(doc)).toBeNull();
  expect(livePlaceholder.style.visibility).toBe("");
  expect(typed).toEqual(["hello"]);
});

test("a second handover while the first waits hands the text over once", () => {
  // The live composer's hole (#50067) and the copy's removal both hand over.
  const { win, doc, copy, typed } = page(PROMPT(EDITABLE), PROMPT(""));
  const field = drawSkeleton(doc, copy, copyPrompt(copy)!)!;
  field.textContent = "hello";
  handOverSkeleton(doc);
  handOverSkeleton(doc);
  doc.querySelector("#root .acpmux-md-root")!.innerHTML = EDITABLE;
  win.dispatchEvent(new win.Event(COMPOSER_READY_EVENT));
  expect(skeletonField(doc)).toBeNull();
  expect(typed).toEqual(["hello"]);
});

test("an empty, unfocused field goes without taking focus", () => {
  const { doc, copy, typed } = page(PROMPT(EDITABLE), '<input id="other">' + PROMPT(EDITABLE));
  const field = drawSkeleton(doc, copy, copyPrompt(copy)!)!;
  doc.getElementById("other")!.focus();
  expect(doc.activeElement).not.toBe(field);
  handOverSkeleton(doc);
  expect(skeletonField(doc)).toBeNull();
  expect(typed).toEqual([]);
  expect(doc.activeElement?.id).toBe("other");
});
