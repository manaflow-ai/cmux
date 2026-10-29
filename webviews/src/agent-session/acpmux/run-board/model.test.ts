import { describe, expect, test } from "bun:test";
import { activity, tool } from "../../../gallery/fixtures/acpmux";
import { sessionSummary } from "../summary/sessionSummary";
import { replayedBoardFixture, runBoardFixture } from "./fixtures";
import { canApprove, evidenceReady, initialBoard, reduceBoard, type RunBoardState } from "./model";

const review = (state: RunBoardState) => reduceBoard(state, { type: "review", checked: true });

describe("Run board human intent", () => {
  test("selection and attachment are independent, and attachment needs a live owner", () => {
    let state = reduceBoard(initialBoard(runBoardFixture), { type: "attach" });
    state = reduceBoard(state, { type: "select", attemptId: "attempt-b" });
    expect(state.selected).toBe("attempt-b");
    expect(state.attached).toBe("attempt-a");
    state = reduceBoard(state, { type: "disconnect" });
    expect(reduceBoard(state, { type: "attach" }).attached).toBe("attempt-a");
  });

  test("an attempt cannot advance before verified build, tests and all three artifact kinds", () => {
    for (const attempt of runBoardFixture.attempts) {
      let state = reduceBoard(initialBoard(runBoardFixture), { type: "select", attemptId: attempt.id });
      expect(canApprove(state)).toBe(false);
      state = review(state);
      expect(canApprove(state)).toBe(attempt.state === "completed");
    }
    const attempt = runBoardFixture.attempts[0]!;
    expect(evidenceReady({ ...attempt, tests: { passed: 28, failed: 1 } })).toBe(false);
    expect(
      evidenceReady({
        ...attempt,
        artifacts: [...attempt.artifacts, { ...attempt.artifacts[0]!, id: "extra", verified: false }],
      }),
    ).toBe(false);
    for (const artifact of attempt.artifacts) {
      expect(
        evidenceReady({ ...attempt, artifacts: attempt.artifacts.filter((item) => item.id !== artifact.id) }),
      ).toBe(false);
      expect(
        evidenceReady({
          ...attempt,
          artifacts: attempt.artifacts.map((item) => (item.id === artifact.id ? { ...item, verified: false } : item)),
        }),
      ).toBe(false);
    }
  });

  test("approval binds the human review to one attempt, cursor and artifact digests", () => {
    const state = reduceBoard(review(initialBoard(runBoardFixture)), { type: "approve" });
    expect(state.approval).toEqual({
      runId: runBoardFixture.id,
      attemptId: "attempt-a",
      cursor: "143",
      digests: runBoardFixture.attempts[0]!.artifacts.map((item) => item.digest),
    });
    expect(canApprove(state)).toBe(false);
    expect(reduceBoard(state, { type: "approve" })).toBe(state);
  });

  test("disconnect blocks approval; replay preserves selection and never creates an attempt", () => {
    let state = reduceBoard(review(initialBoard(runBoardFixture)), { type: "disconnect" });
    expect(canApprove(state)).toBe(false);
    state = reduceBoard(state, { type: "receive", snapshot: replayedBoardFixture });
    expect(state.connection).toBe("live");
    expect(state.selected).toBe("attempt-a");
    expect(state.snapshot.attempts.map((attempt) => attempt.id)).toEqual(
      runBoardFixture.attempts.map((attempt) => attempt.id),
    );
    expect(state.snapshot.attempts[2]!.state).toBe("completed");
    expect(state.reviewed).toBeUndefined();
  });

  test("old or other-run snapshots cannot replace a newer mirror", () => {
    const state = initialBoard(replayedBoardFixture);
    expect(reduceBoard(state, { type: "receive", snapshot: runBoardFixture })).toBe(state);
    expect(reduceBoard(state, { type: "receive", snapshot: { ...replayedBoardFixture, id: "other-run" } })).toBe(state);
    const large = { ...runBoardFixture, cursor: "9007199254740993" };
    expect(
      reduceBoard(initialBoard(large), { type: "receive", snapshot: { ...large, cursor: "9007199254740992" } }).snapshot
        .cursor,
    ).toBe(large.cursor);
  });

  test("switching attempts requires a fresh human review", () => {
    const state = reduceBoard(review(initialBoard(runBoardFixture)), { type: "select", attemptId: "attempt-b" });
    expect(canApprove(state)).toBe(false);
    expect(canApprove(review(state))).toBe(true);
  });

  test("new owner evidence invalidates a previously prepared integration request", () => {
    const approved = reduceBoard(review(initialBoard(runBoardFixture)), { type: "approve" });
    const replayed = reduceBoard(approved, { type: "receive", snapshot: replayedBoardFixture });
    expect(replayed.approval).toBeUndefined();
    expect(canApprove(replayed)).toBe(false);
  });

  test("attempt change summaries reuse real acpmux tool diffs", () => {
    expect(sessionSummary(runBoardFixture.attempts[0]!.rows).outputs.map((output) => output.path)).toEqual([
      "src/workspace/Workspace.tsx",
      "src/workspace/styles.css",
    ]);
  });

  test("summary Outputs exclude files outside the session project folder", () => {
    const rows = [
      activity(
        [
          tool("Write project and scratch files", "edit", "completed", {
            diffs: [
              { path: "/work/project/src/main.ts", newText: "export {}" },
              { path: "/tmp/m1076.txt", newText: "scratch" },
              { path: "/work/project/../tmp/m1077.txt", newText: "scratch" },
              { path: "m1078.txt", canonical: "/tmp/m1078.txt", newText: "scratch" },
            ],
          }),
        ],
        1,
      ),
    ];
    expect(sessionSummary(rows, undefined, "/work/project").outputs.map((output) => output.path)).toEqual([
      "/work/project/src/main.ts",
    ]);
  });
});
