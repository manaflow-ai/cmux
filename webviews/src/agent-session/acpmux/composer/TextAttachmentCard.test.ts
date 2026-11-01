import { expect, test } from "bun:test";
import { TEXT_CARD_LINE_CHARS, TEXT_CARD_LINES, textPreview } from "./TextAttachmentCard";

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
