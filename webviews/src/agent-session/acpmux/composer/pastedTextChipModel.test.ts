import { expect, test } from "bun:test";
import type { Translate } from "../i18n";
import { LABEL_SEPARATOR, PASTE_CHIP_DESIGN, pastedSizeParts } from "./pastedTextChipModel";
import { pastedSize } from "./textAttachmentCardModel";

const t = ((key: string, values?: Record<string, string | number>) =>
  key === "composer.pastedChars"
    ? `${values?.count ?? ""} characters`
    : `${values?.count ?? ""} ${values?.n === 1 ? "line" : "lines"}`) as Translate;

// The chip's label drops its parts from the end when it has no room (PastedTextChip.tsx): the size
// goes first, then the line count, so the parts come in that order after the name.
test("a paste's size parts are its lines, then its characters", () => {
  const log = Array.from({ length: 57 }, () => "x".repeat(110)).join("\n");
  expect(pastedSizeParts(t, "en", log)).toEqual(["57 lines", "6.3K characters"]);
});

test("one long paragraph has only its characters, never 1 line", () => {
  expect(pastedSizeParts(t, "en", "word ".repeat(2_000))).toEqual(["10K characters"]);
});

test("the joined size reads as the parts do", () => {
  const log = Array.from({ length: 42 }, () => "x".repeat(42)).join("\n");
  expect(pastedSize(t, "en", log)).toBe(pastedSizeParts(t, "en", log).join(LABEL_SEPARATOR));
});

// Leo, 2026-11-08: "maybe in claude you see it in a viewer?". The composer opens a paste in the
// sheet; the other designs are drawn only in the gallery.
test("the composer's chip opens its text in a sheet", () => {
  expect(PASTE_CHIP_DESIGN).toBe("sheet");
});
