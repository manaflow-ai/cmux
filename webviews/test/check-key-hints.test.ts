import { describe, expect, test } from "bun:test";
import { cssKeyHintFindings, keyHintFindings } from "../scripts/check-key-hints";

const lines = (file: string, text: string) => keyHintFindings(file, text).map((f) => f.line);
const css = (text: string) => cssKeyHintFindings("x/x.css", text).map((f) => f.line);

describe("key hint guard", () => {
  test("refuses a <kbd> element", () => {
    expect(lines("A.tsx", "const A = () => <kbd>K</kbd>;")).toEqual([1]);
    expect(lines("A.tsx", "const A = () => <kbd />;")).toEqual([1]);
  });

  test('refuses createElement("kbd") and a local helper that makes one', () => {
    expect(lines("a.ts", 'const k = document.createElement("kbd");')).toEqual([1]);
    expect(lines("a.ts", 'const k = make(doc, "kbd", "x");')).toEqual([1]);
  });

  test("lets a sanitizer list kbd as an allowed tag", () => {
    expect(lines("a.ts", 'const TAGS = new Set(["kbd", "code"]);\nallow(["kbd", "code"], x);')).toEqual([]);
  });

  test("refuses a keycap class outside the component", () => {
    expect(lines("A.tsx", 'const A = () => <span className="foo-keycap" />;')).toEqual([1]);
    expect(lines("a.ts", 'el.className = "row foo-kbd";')).toEqual([1]);
    expect(lines("a.ts", 'el.classList.add("x-key-hint");')).toEqual([1]);
    expect(lines("A.tsx", 'const A = () => <span className={cx("row", on && "x-keyhint")} />;')).toEqual([1]);
    expect(lines("A.tsx", 'const A = () => <span className="ui-key-hint ui-key-hint-key" />;')).toEqual([]);
  });

  test("refuses a shortcut drawn as raw text", () => {
    expect(lines("A.tsx", "const A = () => <span>⌘K</span>;")).toEqual([1]);
    expect(lines("A.tsx", 'const A = () => <span>{"⌃⌘M"}</span>;')).toEqual([1]);
    expect(lines("a.ts", 'el.textContent = "⇧⌘P";')).toEqual([1]);
  });

  test("leaves KeyHint props, attributes and data alone", () => {
    expect(lines("A.tsx", 'const A = () => <KeyHint keys="⌘K" />;')).toEqual([]);
    expect(lines("A.tsx", 'const A = () => <button aria-keyshortcuts="Meta+K" title="Copy ⌘C" />;')).toEqual([]);
    expect(lines("a.ts", 'const KEYS = { copy: "⌘C" };')).toEqual([]);
  });

  test("the component's own files may draw it", () => {
    expect(lines("ui/keyHintModel.ts", 'doc.createElement("kbd");')).toEqual([]);
    expect(lines("ui/KeyHint.tsx", "const K = () => <kbd />;")).toEqual([]);
  });

  test("an allow comment needs a reason", () => {
    expect(lines("A.tsx", "// key-hint-allow: a recorded keystroke\nconst A = () => <kbd />;")).toEqual([]);
    expect(lines("A.tsx", "const A = () => <kbd />; // key-hint-allow: a recorded keystroke")).toEqual([]);
    expect(lines("A.tsx", "// key-hint-allow:\nconst A = () => <kbd />;")).toEqual([2]);
  });

  test("refuses keycap selectors and bare kbd in stylesheets", () => {
    expect(css(".x-keycap { color: red; }")).toEqual([1]);
    expect(css("kbd { font: inherit; }")).toEqual([1]);
    expect(css(".row > kbd,\n.row .x-kbd { gap: 0; }")).toEqual([1, 2]);
    expect(css(".ui-key-hint { color: red; }\n.keyboard-row { gap: 0; }")).toEqual([]);
    expect(css("/* key-hint-allow: user content */\nkbd { font: inherit; }")).toEqual([]);
    expect(css("/* key-hint-allow: */\nkbd { font: inherit; }")).toEqual([2]);
    expect(cssKeyHintFindings("ui/keyHint.css", ".ui-key-hint kbd {}")).toEqual([]);
  });
});
