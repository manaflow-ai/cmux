import { expect, test } from "bun:test";
import { GALLERY_NOW, minutesAgo } from "../../../gallery/clock";
import { session } from "../../../gallery/fixtures/acpmux";
import {
  changesPrompt,
  nextReads,
  readKey,
  readReviewStat,
  reviewCandidates,
  reviewRows,
  verdictTag,
  type ReviewRead,
} from "./reviewModel";

/// The fixtures' times are relative to the gallery clock, so the queue reads them at that clock.
const candidatesAt = (sessions: Parameters<typeof reviewCandidates>[0]) => reviewCandidates(sessions, GALLERY_NOW);

const diff = (paths: string[], head = "a1") => ({
  scope: "branch",
  head,
  files: paths.map((path) => ({ path, status: "modified", additions: 3, deletions: 1 })),
  additions: paths.length * 3,
  deletions: paths.length,
  total_files: paths.length,
});

test("one row per folder, owned by its latest chat; idle chats first, newest first", () => {
  const candidates = candidatesAt([
    session({ sessionId: "a", worktree: "/wt/a", activityAt: minutesAgo(30) }),
    session({ sessionId: "a2", worktree: "/wt/a", activityAt: minutesAgo(10) }),
    session({ sessionId: "b", worktree: "/wt/b", activityAt: minutesAgo(5), lane: "working" }),
    session({ sessionId: "c", worktree: "/wt/c", activityAt: minutesAgo(20) }),
  ]);
  expect(candidates.map((candidate) => [candidate.key, candidate.owner.sessionId, candidate.others])).toEqual([
    ["/wt/a", "a2", 1],
    ["/wt/c", "c", 0],
    ["/wt/b", "b", 0],
  ]);
});

test("archived, side, unsent, other machines, merged and stale chats are not candidates", () => {
  const candidates = candidatesAt([
    session({ sessionId: "archived", worktree: "/wt/1", archived: true }),
    session({ sessionId: "side", worktree: "/wt/2", side: true }),
    session({ sessionId: "unsent", worktree: "/wt/3", unsent: true }),
    session({ sessionId: "peer", worktree: "/wt/4", peer: "vm" }),
    session({ sessionId: "cloud", worktree: "/wt/5", hostKind: "cloud" }),
    session({ sessionId: "merged", worktree: "/wt/6", pullRequest: { number: 1, title: "x", state: "merged" } }),
    session({ sessionId: "stale", worktree: "/wt/7", activityAt: minutesAgo(60 * 24 * 30) }),
    session({ sessionId: "kept", worktree: "/wt/8" }),
  ]);
  expect(candidates.map((candidate) => candidate.owner.sessionId)).toEqual(["kept"]);
});

test("a stat's signature follows the files and HEAD, and an empty diff is no stat", () => {
  const one = readReviewStat(diff(["a.ts"]), "branch")!;
  expect(one.totalFiles).toBe(1);
  expect(readReviewStat(diff(["a.ts"]), "branch")!.signature).toBe(one.signature);
  expect(readReviewStat(diff(["a.ts", "b.ts"]), "branch")!.signature).not.toBe(one.signature);
  expect(readReviewStat(diff(["a.ts"], "b2"), "branch")!.signature).not.toBe(one.signature);
  expect(readReviewStat(diff([]), "branch")).toBeUndefined();
});

test("rows arrive in order: none shows below a folder still being read", () => {
  const candidates = candidatesAt([
    session({ sessionId: "a", worktree: "/wt/a", activityAt: minutesAgo(1) }),
    session({ sessionId: "b", worktree: "/wt/b", activityAt: minutesAgo(2) }),
    session({ sessionId: "c", worktree: "/wt/c", activityAt: minutesAgo(3) }),
  ]);
  const stat = readReviewStat(diff(["x.ts"]), "branch");
  const reads = new Map<string, ReviewRead>([
    [readKey(candidates[0]!), { state: "read", stat }],
    [readKey(candidates[1]!), { state: "reading" }],
    [readKey(candidates[2]!), { state: "read", stat }],
  ]);
  const shown = reviewRows(candidates, reads);
  expect(shown.rows.map((row) => row.key)).toEqual(["/wt/a"]);
  expect(shown.pending).toBe(true);
  reads.set(readKey(candidates[1]!), { state: "read" });
  expect(reviewRows(candidates, reads).rows.map((row) => row.key)).toEqual(["/wt/a", "/wt/c"]);
});

test("a verdict hides the row until the folder's changes differ", () => {
  const stat = readReviewStat(diff(["x.ts"]), "branch")!;
  const tagged = (done?: string) =>
    candidatesAt([session({ sessionId: "a", worktree: "/wt/a", ...(done ? { reviewDone: done } : {}) })]);
  const rows = (done?: string, value = stat) => {
    const candidates = tagged(done);
    return reviewRows(candidates, new Map([[readKey(candidates[0]!), { state: "read", stat: value }]])).rows;
  };
  expect(rows()).toHaveLength(1);
  expect(rows(verdictTag("accepted", stat))).toHaveLength(0);
  expect(rows(verdictTag("changes", stat))).toHaveLength(0);
  expect(rows(verdictTag("accepted", stat), readReviewStat(diff(["x.ts", "y.ts"]), "branch")!)).toHaveLength(1);
  const candidates = tagged();
  const local = new Set([`/wt/a:${stat.signature}`]);
  expect(reviewRows(candidates, new Map([[readKey(candidates[0]!), { state: "read", stat }]]), local).rows).toHaveLength(0);
});

test("reads stay within a window past what is reached, however many chats there are", () => {
  const candidates = candidatesAt(
    Array.from({ length: 500 }, (_, index) =>
      session({ sessionId: `s${index}`, worktree: `/wt/${index}`, activityAt: minutesAgo(index + 1) }),
    ),
  );
  expect(nextReads(candidates, new Map(), 0)).toHaveLength(12);
  const reads = new Map<string, ReviewRead>(candidates.slice(0, 12).map((candidate) => [readKey(candidate), { state: "read" }]));
  const { reached } = reviewRows(candidates, reads);
  expect(reached).toBe(12);
  expect(nextReads(candidates, reads, reached).map((candidate) => candidate.key)).toEqual(
    candidates.slice(12, 24).map((candidate) => candidate.key),
  );
});

test("Request changes names the branch and the change before the person's words", () => {
  const candidates = candidatesAt([session({ sessionId: "a", worktree: "/wt/a", branch: "lane/x" })]);
  const stat = readReviewStat(diff(["x.ts", "y.ts"]), "branch")!;
  expect(changesPrompt({ ...candidates[0]!, stat }, "  Use the shared helper.  ")).toBe(
    "Review of your changes on lane/x (2 files, +6 −2): changes requested.\n\nUse the shared helper.",
  );
});
