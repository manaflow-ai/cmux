import { expect, test } from "bun:test";
import { isEmptyBrief, parseReviewBrief, snippetLine, spotTarget, type BriefSpot } from "./model";

// The answer acpmux gives for the fixture chat `review_brief_fixtures/claude.ndjson`
// (`review_brief_tests.rs`), with the diff's repository root.
const ANSWER = {
  sessionId: "chat",
  seq: 17,
  brief: {
    goal: "Make the uploader retry failed chunks with backoff, and keep the progress bar honest.",
    planText: "Retry each chunk; clamp progress.",
    plan: [
      { content: "Find where chunks are sent", status: "completed" },
      { content: "Add retry with backoff", status: "in_progress" },
    ],
    rejected: [{ text: "Wrapping the whole upload in a retry loop didn't work.", seq: 4 }],
    unsure: [
      { kind: "redone", path: "src/upload.rs", snippet: "retry(|| send(chunk))?;", seq: 9 },
      { kind: "hedge", text: "I'm not sure the backoff cap is right.", path: "src/upload.rs", seq: 11 },
      { kind: "hedge", text: "Untested on resumed uploads.", seq: 11 },
      { kind: "guess", path: "src/x.rs", seq: 12 },
    ],
  },
};

test("an answer parses into the brief; an unknown spot kind is left out", () => {
  const brief = parseReviewBrief(ANSWER);
  expect(brief?.goal).toBe(ANSWER.brief.goal);
  expect(brief?.plan.map((item) => item.status)).toEqual(["completed", "in_progress"]);
  expect(brief?.rejected).toHaveLength(1);
  expect(brief?.unsure.map((spot) => spot.kind)).toEqual(["redone", "hedge", "hedge"]);
  expect(brief?.unsure[2]?.path).toBe("");
});

test("what is not a brief parses to null; an empty brief is empty", () => {
  expect(parseReviewBrief(null)).toBeNull();
  expect(parseReviewBrief("brief")).toBeNull();
  expect(parseReviewBrief({ sessionId: "chat" })).toBeNull();
  const empty = parseReviewBrief({ brief: { goal: "", unsure: [] } });
  expect(empty && isEmptyBrief(empty)).toBe(true);
  expect(isEmptyBrief(parseReviewBrief(ANSWER)!)).toBe(false);
});

// `fn send` became a retry at new line 42; an undo took out `old()` at old line 10.
const FILE_DIFF = {
  hunks: [
    {
      additionStart: 40,
      additionCount: 3,
      additionLineIndex: 0,
      deletionStart: 40,
      deletionCount: 3,
      deletionLineIndex: 0,
    },
    {
      additionStart: 10,
      additionCount: 0,
      additionLineIndex: 3,
      deletionStart: 10,
      deletionCount: 1,
      deletionLineIndex: 3,
    },
  ],
  additionLines: ["fn upload() {", "    let n = 0;", "    retry(|| send(chunk))?;"],
  deletionLines: ["fn upload() {", "    let n = 0;", "    send(chunk)?;", "    old();"],
};

test("a snippet finds its line on the new side first, then the old side", () => {
  expect(snippetLine(FILE_DIFF, "retry(|| send(chunk))?;")).toEqual({ lineNumber: 42, side: "additions" });
  expect(snippetLine(FILE_DIFF, "old();")).toEqual({ lineNumber: 10, side: "deletions" });
  expect(snippetLine(FILE_DIFF, "retry(|| send(…")).toEqual({ lineNumber: 42, side: "additions" });
  expect(snippetLine(FILE_DIFF, "nowhere")).toBeUndefined();
  expect(snippetLine(undefined, "old();")).toBeUndefined();
});

test("a spot targets its file's item and line; a file not in the diff has no target", () => {
  const items = [
    { id: "a", fileDiff: FILE_DIFF, name: "src/upload.rs" },
    { id: "b", name: "src/progress.rs" },
  ];
  const byName = (list: readonly (typeof items)[number][], path: string) => list.find((i) => i.name === path)?.id;
  const spot = (fields: Partial<BriefSpot>): BriefSpot => ({
    kind: "hedge",
    text: "",
    path: "",
    snippet: "",
    count: 0,
    seq: 1,
    ...fields,
  });
  expect(spotTarget(items, spot({ path: "src/upload.rs", snippet: "retry(|| send(chunk))?;" }), byName)).toEqual({
    itemId: "a",
    lineNumber: 42,
    side: "additions",
  });
  expect(spotTarget(items, spot({ path: "src/progress.rs", line: 7 }), byName)).toEqual({
    itemId: "b",
    lineNumber: 7,
    side: "additions",
  });
  expect(spotTarget(items, spot({ path: "src/progress.rs" }), byName)).toEqual({ itemId: "b" });
  expect(spotTarget(items, spot({ path: "src/gone.rs" }), byName)).toBeUndefined();
  expect(spotTarget(items, spot({}), byName)).toBeUndefined();
});
