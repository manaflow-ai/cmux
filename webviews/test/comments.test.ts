import { expect, test } from "bun:test";
import { anchorComment, excerptFor, lineIndexFor, lineTextFor, type CommentFileDiff } from "../src/comments/anchor";
import {
  annotationsForItem,
  applyCommentAnnotations,
  sidebarCommentEntries,
  withCommentAnnotations,
} from "../src/comments/annotations";
import { commentDisplayName, commentSubmissionText } from "../src/comments/format";
import { resolveCommentLabels } from "../src/comments/labels";
import type { DiffCommentRecord } from "../src/comments/types";
import type { DiffItem } from "../src/diff-stream";

// Two hunks on each side:
//   additions: lines 10-12 (indexes 0-2) and lines 30-31 (indexes 3-4)
//   deletions: lines 9-10 (indexes 0-1) and lines 28-29 (indexes 2-3)
const fileDiff: CommentFileDiff & { name: string } = {
  name: "src/example.ts",
  hunks: [
    {
      additionStart: 10,
      additionCount: 3,
      additionLineIndex: 0,
      deletionStart: 9,
      deletionCount: 2,
      deletionLineIndex: 0,
    },
    {
      additionStart: 30,
      additionCount: 2,
      additionLineIndex: 3,
      deletionStart: 28,
      deletionCount: 2,
      deletionLineIndex: 2,
    },
  ],
  additionLines: ["const a = 1;", "const b = 2;", "const c = 3;", "return a;", "return b;"],
  deletionLines: ["let a = 1;", "let b = 2;", "yield a;", "yield b;"],
};

function comment(overrides: Partial<DiffCommentRecord> = {}): DiffCommentRecord {
  return {
    id: "c-1",
    filePath: "src/example.ts",
    side: "additions",
    startLine: 10,
    endLine: 11,
    lineText: "const b = 2;",
    message: "rename this",
    createdAt: "2026-01-01T00:00:00Z",
    updatedAt: "2026-01-01T00:00:00Z",
    ...overrides,
  };
}

function item(overrides: Partial<DiffItem> = {}): DiffItem {
  return { id: "src/example.ts", type: "diff", fileDiff, version: 0, ...overrides } as DiffItem;
}

test("lineIndexFor maps line numbers across hunks on both sides", () => {
  expect(lineIndexFor(fileDiff, "additions", 10)).toBe(0);
  expect(lineIndexFor(fileDiff, "additions", 12)).toBe(2);
  expect(lineIndexFor(fileDiff, "additions", 30)).toBe(3);
  expect(lineIndexFor(fileDiff, "additions", 31)).toBe(4);
  expect(lineIndexFor(fileDiff, "additions", 13)).toBeNull();
  expect(lineIndexFor(fileDiff, "additions", 9)).toBeNull();
  expect(lineIndexFor(fileDiff, "deletions", 9)).toBe(0);
  expect(lineIndexFor(fileDiff, "deletions", 29)).toBe(3);
  expect(lineIndexFor(fileDiff, "deletions", 11)).toBeNull();
});

test("lineTextFor reads side-specific content", () => {
  expect(lineTextFor(fileDiff, "additions", 11)).toBe("const b = 2;");
  expect(lineTextFor(fileDiff, "deletions", 28)).toBe("yield a;");
  expect(lineTextFor(fileDiff, "additions", 99)).toBeNull();
});

test("anchorComment keeps a comment whose line still matches", () => {
  expect(anchorComment(fileDiff, comment())).toEqual({ state: "anchored", line: 11 });
});

test("anchorComment re-anchors a uniquely moved line", () => {
  const moved = comment({ endLine: 31, lineText: "const b = 2;" });
  expect(anchorComment(fileDiff, moved)).toEqual({ state: "moved", line: 11, delta: -20 });
});

test("anchorComment marks missing or ambiguous lines outdated", () => {
  expect(anchorComment(fileDiff, comment({ lineText: "gone forever" }))).toEqual({ state: "outdated" });
  const ambiguous: CommentFileDiff = {
    ...fileDiff,
    additionLines: ["dup", "dup", "x", "y", "z"],
  };
  expect(
    anchorComment(ambiguous, comment({ endLine: 12, lineText: "dup" })),
  ).toEqual({ state: "outdated" });
});

test("excerptFor renders line-numbered content and skips uncovered lines", () => {
  expect(excerptFor(fileDiff, "additions", 11, 12)).toBe("11: const b = 2;\n12: const c = 3;");
  expect(excerptFor(fileDiff, "additions", 12, 30)).toBe("12: const c = 3;\n30: return a;");
});

test("commentDisplayName collapses single-line ranges", () => {
  expect(commentDisplayName(comment())).toBe("example.ts:10-11");
  expect(commentDisplayName(comment({ startLine: 11, endLine: 11 }))).toBe("example.ts:11");
});

test("commentSubmissionText formats the submission text", () => {
  expect(commentSubmissionText(comment(), fileDiff)).toBe(
    "Review comment on src/example.ts lines 10-11 (new version):\n\n" +
      "10: const a = 1;\n11: const b = 2;\n\n" +
      "rename this\n",
  );
});

test("commentSubmissionText marks deletion-side comments as old version", () => {
  const submissionText = commentSubmissionText(
    comment({ side: "deletions", startLine: 28, endLine: 28, lineText: "yield a;" }),
    fileDiff,
  );
  expect(submissionText).toContain("line 28 (old version)");
  expect(submissionText).toContain("28: yield a;");
});

test("annotationsForItem anchors comments and appends the draft", () => {
  const annotations = annotationsForItem(
    item(),
    [comment(), comment({ id: "c-2", lineText: "gone forever" })],
    { itemId: "src/example.ts", side: "additions", startLine: 30, endLine: 30 },
  );
  expect(annotations).toHaveLength(2);
  expect(annotations[0]).toMatchObject({ side: "additions", lineNumber: 11 });
  expect(annotations[1]).toMatchObject({ lineNumber: 30, metadata: { kind: "draft" } });
});

test("applyCommentAnnotations bumps versions only for changed items", () => {
  const target = item();
  const untouched = item({ id: "other.ts", fileDiff: { ...fileDiff, name: "other.ts" } });
  const record = comment();
  const next = applyCommentAnnotations([target, untouched], [record], null);
  expect(next[0]).not.toBe(target);
  expect(next[0].version).toBe(1);
  expect(next[0].annotations).toHaveLength(1);
  expect(next[1]).toBe(untouched);

  // Same record instance (as in app state between renders) is a no-op.
  const again = applyCommentAnnotations(next, [record], null);
  expect(again).toBe(next);
});

test("withCommentAnnotations leaves unrelated streamed items untouched", () => {
  const unrelated = item({ id: "other.ts", fileDiff: { ...fileDiff, name: "other.ts" } });
  expect(withCommentAnnotations(unrelated, [comment()], null)).toBe(unrelated);
  const related = withCommentAnnotations(item(), [comment()], null);
  expect(related.annotations).toHaveLength(1);
});

test("sidebarCommentEntries includes outdated comments with a fallback item", () => {
  const entries = sidebarCommentEntries(
    [item()],
    [comment(), comment({ id: "c-2", lineText: "gone forever" })],
  );
  expect(entries).toHaveLength(2);
  expect(entries[0]).toMatchObject({ itemId: "src/example.ts", anchor: { state: "anchored" }, pending: false });
  expect(entries[1]).toMatchObject({ itemId: "src/example.ts", anchor: { state: "outdated" }, pending: false });
});

test("sidebarCommentEntries marks unmatched comments pending while streaming", () => {
  const streaming = sidebarCommentEntries([], [comment()], false);
  expect(streaming[0]).toMatchObject({ itemId: null, pending: true });

  const complete = sidebarCommentEntries([], [comment()], true);
  expect(complete[0]).toMatchObject({ itemId: null, pending: false, anchor: { state: "outdated" } });
});

test("resolveCommentLabels prefers payload labels and falls back to English", () => {
  const labels = resolveCommentLabels({ labels: { comments: "コメント" } });
  expect(labels.comments).toBe("コメント");
  expect(labels.addComment).toBe("Add comment");
});

test("diffExcerptFor renders paired -/+ rows with trimmed context", async () => {
  const { diffExcerptFor } = await import("../src/comments/anchor");
  const withContent = {
    ...fileDiff,
    hunks: [
      {
        additionStart: 10,
        additionCount: 3,
        additionLineIndex: 0,
        deletionStart: 9,
        deletionCount: 2,
        deletionLineIndex: 0,
        hunkContent: [
          { type: "context" as const, lines: 1, additionLineIndex: 0, deletionLineIndex: 0 },
          { type: "change" as const, deletions: 1, deletionLineIndex: 1, additions: 2, additionLineIndex: 1 },
        ],
      },
    ],
  };
  // Comment on the added lines 11-12: the paired deletion shows too.
  expect(diffExcerptFor(withContent, "additions", 11, 12)).toBe(
    "-let b = 2;\n+const b = 2;\n+const c = 3;",
  );
  // Comment including the leading context line 10.
  expect(diffExcerptFor(withContent, "additions", 10, 12)).toBe(
    " const a = 1;\n-let b = 2;\n+const b = 2;\n+const c = 3;",
  );
  // No hunkContent → empty (submission falls back to numbered excerpt).
  expect(diffExcerptFor(fileDiff, "additions", 10, 12)).toBe("");
});
