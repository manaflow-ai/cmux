// Merge readiness follows the gates the merge path enforces (merge_hold.py, review_model.py): a
// different family's SHIP at the exact head, no wait verdict at the head, no hold, no red of its
// own, nothing running, and main's by-name approval.
import { expect, test } from "bun:test";
import {
  mockBlocked,
  mockBlockedChecks,
  mockBlockedDetails,
  mockReady,
  mockReadyChecks,
  mockReadyDetails,
} from "./mockReadiness";
import { authorFamily, readiness, receipts, reviewerFamily } from "./readiness";
import type { ConversationEntry, PullRequestDetails } from "./types";

const HEAD = mockReadyDetails.headCommit;
const comment = (body: string): ConversationEntry => ({
  kind: "comment",
  author: "octocat",
  body,
  at: "2026-11-05T03:00:00Z",
  url: null,
  state: null,
  comments: [],
});
const withEntries = (details: PullRequestDetails, ...bodies: string[]): PullRequestDetails => ({
  ...details,
  conversation: bodies.map(comment),
});
const kinds = (details: PullRequestDetails, pr = mockReady.pullRequest!, checks = mockReadyChecks) =>
  readiness(pr, details, checks).blockers.map((blocker) => blocker.kind);

test("a different family's SHIP at the head, green and unheld into feat-cmux-next, is ready", () => {
  const state = readiness(mockReady.pullRequest!, mockReadyDetails, mockReadyChecks);
  expect(state.state).toBe("ready");
  expect(state.blockers).toEqual([]);
  expect(state.ship?.model).toBe("gpt-6.1-sol");
  expect(state.ship?.family).toBe("codex");
});

test("the blocked fixture names each gate, in the order the merge path checks them", () => {
  const state = readiness(mockBlocked.pullRequest!, mockBlockedDetails, mockBlockedChecks);
  expect(state.state).toBe("blocked");
  expect(state.blockers.map((blocker) => blocker.kind)).toEqual(["verdict", "review", "hold", "red", "running"]);
  const review = state.blockers.find((blocker) => blocker.kind === "review");
  expect(review?.kind === "review" && review.older?.sha.startsWith("9a8b7c6")).toBe(true);
  const hold = state.blockers.find((blocker) => blocker.kind === "hold");
  expect(hold?.kind === "hold" && hold.line).toBe("HOLD: waiting for the nightly cut");
  const red = state.blockers.find((blocker) => blocker.kind === "red");
  // The base's own red (`onBase`) is not this pull request's.
  expect(red?.kind === "red" && red.checks.every((check) => !check.job?.onBase)).toBe(true);
});

test("a SHIP from the author's own family, a subagent or an unnamed reviewer does not count", () => {
  for (const reviewer of ["claude-opus-5-5, started by aid-1", "subagent", "a reviewer"]) {
    const details = withEntries(mockReadyDetails, `Review (${reviewer}): SHIP at ${HEAD}`);
    expect(kinds(details)).toEqual(["review"]);
  }
  // A person counts whatever the author's family.
  expect(kinds(withEntries(mockReadyDetails, `Review (Leo): SHIP at ${HEAD}`))).toEqual([]);
  // A Codex-written pull request needs a Claude (or a person's) review.
  const codex = { ...mockReadyDetails, body: "Generated with [Codex](https://openai.com/codex)" };
  expect(kinds(withEntries(codex, `Review (gpt-6.1-sol): SHIP at ${HEAD}`))).toEqual(["review"]);
  expect(kinds(withEntries(codex, `Review (claude-opus-5-5): SHIP at ${HEAD}`))).toEqual([]);
});

test("a SHIP at another commit does not count, and a later SHIP does not clear a BLOCK at the head", () => {
  const older = "0".repeat(40);
  expect(kinds(withEntries(mockReadyDetails, `Review (gpt-6.1-sol): SHIP at ${older}`))).toEqual(["review"]);
  expect(
    kinds(
      withEntries(mockReadyDetails, `Review (gpt-6.1-sol): BLOCK at ${HEAD}`, `Review (gpt-6-astra): SHIP at ${HEAD}`),
    ),
  ).toEqual(["verdict"]);
  // A short or longer hex is not the head.
  expect(kinds(withEntries(mockReadyDetails, `Review (gpt-6.1-sol): SHIP at ${HEAD}0`))).toEqual(["review"]);
});

test("receipts read the verdict, the head and the model; families follow review_model", () => {
  const [ship] = receipts(withEntries(mockReadyDetails, `Review (gpt-6.1-sol, router-review): NOT SHIP at ${HEAD}`));
  expect(ship?.verdict).toBe("wait");
  expect(ship?.word).toBe("NOT SHIP");
  expect(reviewerFamily("router-review")).toBe("codex");
  expect(reviewerFamily("claude sonnet")).toBe("claude");
  expect(reviewerFamily("human")).toBe("person");
  expect(authorFamily("Generated with [Claude Code] ... Generated with [Codex]")).toBe("mixed");
  expect(authorFamily("no footer")).toBeNull();
});

test("a hold label, a draft, a conflict and a pull request into main each block", () => {
  const pr = mockReady.pullRequest!;
  expect(kinds(mockReadyDetails, { ...pr, labels: ["do-not-merge"] })).toEqual(["hold"]);
  expect(kinds(mockReadyDetails, { ...pr, state: "draft" })).toEqual(["draft"]);
  expect(kinds(mockReadyDetails, { ...pr, mergeable: "conflicting" })).toEqual(["conflict"]);
  expect(kinds(mockReadyDetails, { ...pr, baseRef: "main" })).toEqual(["main"]);
  // "Hold" in a sentence is not a hold line.
  expect(kinds({ ...mockReadyDetails, body: `${mockReadyDetails.body}\nWe hold the lock while it runs.` })).toEqual([]);
  expect(readiness({ ...pr, state: "merged" }, mockReadyDetails, mockReadyChecks).state).toBe("merged");
});

test("without the dashboard, the rollup's own reds and pending checks block", () => {
  const pr = mockBlocked.pullRequest!;
  const state = readiness(pr, mockReadyDetails, null);
  const red = state.blockers.find((blocker) => blocker.kind === "red");
  expect(red?.kind === "red" && red.checks.map((check) => check.name)).toEqual(["unit tests"]);
  expect(state.blockers.find((blocker) => blocker.kind === "running")).toEqual({ kind: "running", count: 1 });
});
