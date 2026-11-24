// l10n-allow-file: synthetic draft lines, not shipped UI.
// The send morph's copy of a long draft is the lines its field shows, not every line (sendMorph.ts
// copyText). Leo, 2026-11-22: "THE FUCSKING COLLAPSING OF THE FUCKING COMPOSER / IT TAKES TOO FUCKING
// LONG": copying a 2000-line draft (a clone and a style read per element) held the send's task.
import { expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { copyText } from "./sendMorph";

test("a long draft's copy holds only the lines its field shows, where they were drawn", () => {
  const { window } = new JSDOM("<!doctype html><body></body>");
  const scope = globalThis as Record<string, unknown>;
  const had = "getComputedStyle" in scope;
  const saved = scope.getComputedStyle;
  scope.getComputedStyle = window.getComputedStyle.bind(window);
  try {
    const editor = window.document.createElement("div");
    window.document.body.append(editor);
    const line = 20;
    // The editor's top is 1000px above the viewport's: the field scrolled 1000px into the draft.
    const top = -1000;
    for (let index = 0; index < 2000; index += 1) {
      const paragraph = window.document.createElement("p");
      paragraph.textContent = `Line ${index + 1}`;
      paragraph.getBoundingClientRect = () => new window.DOMRect(0, top + index * line, 400, line);
      editor.append(paragraph);
    }
    editor.getBoundingClientRect = () => new window.DOMRect(0, top, 400, 2000 * line);
    // The field shows 200px of it, from y 0.
    const copy = copyText(editor, 400, { top: 0, bottom: 200 });
    const lines = [...copy.querySelectorAll("p")].map((paragraph) => paragraph.textContent);
    expect(lines).toEqual(Array.from({ length: 10 }, (_, index) => `Line ${51 + index}`));
    // A spacer keeps the first copied line at its drawn place (1000px down the copy).
    expect((copy.firstElementChild as HTMLElement).style.height).toBe("1000px");
    // Without a band (a draft the field shows whole) every line is copied.
    expect(copyText(editor, 400).querySelectorAll("p").length).toBe(2000);
  } finally {
    if (had) scope.getComputedStyle = saved;
    else delete scope.getComputedStyle;
  }
});
