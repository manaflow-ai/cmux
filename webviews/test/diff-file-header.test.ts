import { expect, test } from "bun:test";
import type { FileDiffMetadata } from "@pierre/diffs";
import { diffFileLanguageLabel, diffFileLineTotals } from "../src/diff-file-header";

function fileDiff(partial: Partial<FileDiffMetadata>): FileDiffMetadata {
  return { name: "", type: "change", hunks: [], ...partial } as FileDiffMetadata;
}

test("diffFileLanguageLabel maps known languages to friendly badges", () => {
  expect(diffFileLanguageLabel(fileDiff({ name: "src/App.tsx", lang: "tsx" }))).toBe("TSX");
  expect(diffFileLanguageLabel(fileDiff({ name: "src/util.ts", lang: "typescript" }))).toBe("TS");
  expect(diffFileLanguageLabel(fileDiff({ name: "Sources/Foo.swift", lang: "swift" }))).toBe("Swift");
});

test("diffFileLanguageLabel falls back to an uppercased short extension", () => {
  // Unknown-to-the-detector extension that is still short: gets a tidy badge.
  expect(diffFileLanguageLabel(fileDiff({ name: "notes.xyz" }))).toBe("XYZ");
  expect(diffFileLanguageLabel(fileDiff({ name: "data.toml" }))).toBe("TOML");
});

test("diffFileLanguageLabel returns empty string for extensionless unknown files", () => {
  expect(diffFileLanguageLabel(fileDiff({ name: "zzqqxnotathing" }))).toBe("");
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
