// Diff find lowercases each line to search it and reports match offsets into the original line. `İ`
// lowercases to two characters, so every offset after it was one too far and a plain "i" query
// missed it; the find now folds it to "i" first, keeping each character's offset.
import { expect, test } from "bun:test";
import { collectFindMatches } from "../src/find/model";

const item = (lines: string[]) =>
  ({
    id: "a.ts",
    fileDiff: {
      hunks: [
        {
          additionStart: 1,
          additionLineIndex: 0,
          deletionStart: 1,
          deletionLineIndex: 0,
          hunkContent: [{ type: "context", lines: lines.length }],
        },
      ],
      additionLines: lines.map((line) => `${line}\n`),
      deletionLines: lines.map((line) => `${line}\n`),
    },
  }) as never;

test("a match after İ keeps its offset in the original line", () => {
  const [match] = collectFindMatches([item(["İa needle"])], "needle");
  expect(match?.start).toBe(3);
  expect(match?.length).toBe(6);
});

test("a plain i query finds İ, and İ finds i, with the original length", () => {
  expect(collectFindMatches([item(["İstanbul"])], "istanbul").map((match) => [match.start, match.length])).toEqual([
    [0, 8],
  ]);
  expect(collectFindMatches([item(["istanbul"])], "İstanbul").map((match) => [match.start, match.length])).toEqual([
    [0, 8],
  ]);
});

test("several İ before the match shift nothing", () => {
  const [match] = collectFindMatches([item(["İİİ needle"])], "NEEDLE");
  expect(match?.start).toBe(4);
  expect(match?.lineText.slice(match.start, match.start + match.length)).toBe("needle");
});
