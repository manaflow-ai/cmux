import { expect, test } from "bun:test";
import { pasteLines } from "../conversation/promptCollapse";
import type { Translate } from "../i18n";
import {
  pastedSize,
  TEXT_CARD_LINE_CHARS,
  TEXT_CARD_LINES,
  TEXT_CARD_WRAP_CHARS,
  textPreview,
} from "./TextAttachmentCard";

test("the card shows the first lines, from the top", () => {
  const text = Array.from({ length: 40 }, (_, index) => `line ${index + 1}`).join("\n");
  expect(textPreview(text)).toBe(["line 1", "line 2", "line 3", "line 4"].slice(0, TEXT_CARD_LINES).join("\n"));
});

test("leading blank lines are skipped and trailing space dropped; blank lines inside stay", () => {
  expect(textPreview("\n\n  \nRan a command, read a file   \n\n$ bun test\n")).toBe(
    "Ran a command, read a file\n\n$ bun test",
  );
});

test("a long line is cut and a huge paste is read only as far as the card needs", () => {
  const long = "x".repeat(10_000);
  expect(textPreview(long)).toBe("x".repeat(TEXT_CARD_LINE_CHARS));
  const huge = `${"y".repeat(5_000_000)}\nsecond`;
  expect(textPreview(huge).split("\n")).toEqual(["y".repeat(TEXT_CARD_LINE_CHARS), "second"]);
});

test("empty text draws no lines", () => {
  expect(textPreview("")).toBe("");
  expect(textPreview("\n \n")).toBe("");
});

// Leo, 2026-11-05: "it says pasted text one line, but there's a lot more than this". A paste's lines
// can end in \r\n, a lone \r or Unicode's line and paragraph separators, not only \n.
test("a paste's lines are counted whatever ends them", () => {
  expect(pasteLines("one\ntwo\nthree")).toBe(3);
  expect(pasteLines("one\r\ntwo\r\nthree\r\n")).toBe(3);
  expect(pasteLines("one\rtwo\rthree")).toBe(3);
  expect(pasteLines("one two three")).toBe(3);
  expect(pasteLines("one long paragraph with no break at all")).toBe(1);
});

test("the card's lines break wherever the paste's do", () => {
  expect(textPreview("first\rsecond third\r\nfourth")).toBe("first\nsecond\nthird\nfourth");
});

test("a wrapping card keeps enough of one long paragraph to fill its lines", () => {
  const paragraph = Array.from({ length: 300 }, (_, index) => `word${index}`).join(" ");
  const preview = textPreview(paragraph, TEXT_CARD_LINES, TEXT_CARD_WRAP_CHARS);
  expect(preview.length).toBeGreaterThan(TEXT_CARD_LINE_CHARS);
  expect(preview.length).toBeLessThanOrEqual(TEXT_CARD_WRAP_CHARS);
  expect(preview.split(" ").length).toBeGreaterThan(40);
});

test("a paste's size says its lines (when more than one) and its characters", () => {
  const t = ((key: string, values?: Record<string, string | number>) =>
    key === "composer.pastedChars"
      ? `${values?.count ?? ""} characters`
      : `${values?.count ?? ""} ${values?.n === 1 ? "line" : "lines"}`) as Translate;
  expect(pastedSize(t, "en", "x".repeat(4_200))).toBe("4.2K characters");
  expect(pastedSize(t, "en", Array.from({ length: 42 }, () => "x".repeat(42)).join("\n"))).toBe(
    "42 lines · 1.8K characters",
  );
});
