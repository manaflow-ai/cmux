import { expect, test } from "bun:test";
import type { FileDiffMetadata } from "@pierre/diffs";
import { diffFileLanguageLabel, diffFileLineTotals } from "../src/diff-file-header";

function fileDiff(partial: Partial<FileDiffMetadata>): FileDiffMetadata {
  return { name: "", type: "change", hunks: [], ...partial } as FileDiffMetadata;
}

test("diffFileLanguageLabel is the uppercased file extension (locale-independent)", () => {
  expect(diffFileLanguageLabel(fileDiff({ name: "src/App.tsx" }))).toBe("TSX");
  expect(diffFileLanguageLabel(fileDiff({ name: "src/util.ts" }))).toBe("TS");
  expect(diffFileLanguageLabel(fileDiff({ name: "Sources/Foo.swift" }))).toBe("SWIFT");
  expect(diffFileLanguageLabel(fileDiff({ name: "notes.xyz" }))).toBe("XYZ");
  expect(diffFileLanguageLabel(fileDiff({ name: "data.toml" }))).toBe("TOML");
});

test("diffFileLanguageLabel returns empty string for files without a usable extension", () => {
  expect(diffFileLanguageLabel(fileDiff({ name: "zzqqxnotathing" }))).toBe(""); // no extension
  expect(diffFileLanguageLabel(fileDiff({ name: "Makefile" }))).toBe(""); // no extension
  expect(diffFileLanguageLabel(fileDiff({ name: ".gitignore" }))).toBe(""); // dotfile, not an extension
  expect(diffFileLanguageLabel(fileDiff({ name: "archive.tar.gz" }))).toBe("GZ");
  expect(diffFileLanguageLabel(fileDiff({ name: "weird.extension12345" }))).toBe(""); // too long to be a tidy badge
});

test("diffFileLineTotals sums per-hunk addition/deletion line counts", () => {
  const totals = diffFileLineTotals(
    fileDiff({
      hunks: [
        { additionLines: 3, deletionLines: 1 },
        { additionLines: 6, deletionLines: 2 },
      ] as FileDiffMetadata["hunks"],
    }),
  );
  expect(totals).toEqual({ additions: 9, deletions: 3 });
});

test("diffFileLineTotals is zero for an empty hunk list", () => {
  expect(diffFileLineTotals(fileDiff({ hunks: [] }))).toEqual({ additions: 0, deletions: 0 });
});
