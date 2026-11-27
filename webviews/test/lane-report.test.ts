import { expect, test } from "bun:test";
import { laneNotice } from "../src/agent-session/acpmux/conversation/laneReport";

const message = (text: string, extra: Record<string, unknown> = {}) => ({
  name: "review-28631",
  text,
  raw: text,
  ...extra,
});

test("legacy reports collapse the lane line and put session/commits in details", () => {
  const result = laneNotice(
    message(
      "lane report: turn 1 ended, idle.\nReview (Astra): SHIP at 1cb6e90912345678901234567890123456789012\nSession: abc\nCommits named: deadbeef\n(acpmux sends this ... Answer only if it needs you.)",
    ),
  );
  expect(result?.preview).toBe("SHIP at 1cb6e9091234");
  expect(result?.details).toContain("Session: abc");
  expect(result?.details).toContain("Commits named: deadbeef");
  expect(result?.body).toContain("Review (Astra)");
  expect(result?.body).not.toContain("acpmux sends");
});

test("new report verdicts count findings without cutting P1/P2 text", () => {
  const result = laneNotice(
    message(
      "BLOCK at 1cb6e9091234 · 1 P1, 1 P2 · turn 1, idle\n[P1] Keep this entire sentence, including its conclusion.\n[P2] Another complete finding.",
      { report: true, details: { session: "s", commits: ["a"], footer: "hidden" } },
    ),
  );
  expect(result?.preview).toBe("BLOCK at 1cb6e9091234 · 1 P1, 1 P2");
  expect(result?.body).toContain("Keep this entire sentence, including its conclusion.");
  expect(result?.details).toContain('"session": "s"');
});

test("ordinary SHIP prose is not a report without a report marker or turn tail", () => {
  expect(laneNotice(message("Review (Astra): SHIP at 1cb6e90912345678901234567890123456789012"))).toBeUndefined();
});

test("legacy report without Last message previews its first body sentence", () => {
  const result = laneNotice(message("lane report: turn 2 ended, idle.\nThe lane finished cleanly.\nSession: abc"));
  expect(result?.preview).toBe("The lane finished cleanly.");
});

test("inbox notices batch distinct threads and senders", () => {
  const result = laneNotice(
    message(
      "[inbox] New messages from other agents in 3 threads.\n- one (thread from:orch-right-tab/pr:1)\n- two (thread from:orch-msg-rows/pr:2)\n- three (thread from:orch-right-tab/pr:1)",
    ),
  );
  expect(result?.preview).toBe("orch-right-tab, orch-msg-rows");
  expect(result?.threads).toEqual([
    { id: "from:orch-right-tab/pr:1", sender: "orch-right-tab" },
    { id: "from:orch-msg-rows/pr:2", sender: "orch-msg-rows" },
  ]);
});

test("structured inbox threads are authoritative when the parser stripped its prefix", () => {
  const result = laneNotice({
    name: "inbox",
    text: "New messages from other agents in 3 threads.",
    raw: "[inbox] New messages from other agents in 3 threads.",
    noticeThreads: [
      { id: "orch-right-tab/pr:1", sender: "orch-right-tab" },
      { id: "orch-msg-rows/pr:2", sender: "orch-msg-rows" },
    ],
  });
  expect(result?.preview).toBe("orch-right-tab, orch-msg-rows");
});

test("the immutable message object is cached", () => {
  const value = message("lane report: turn 2 ended, idle.\nA plain result.");
  expect(laneNotice(value)).toBe(laneNotice(value));
});

test("signed new report titles expose their verdict", () => {
  const result = laneNotice(
    message("[review-28631] SHIP at 1cb6e9091234 · no findings · turn 1, idle\nNo findings.", {
      report: true,
    }),
  );
  expect(result?.verdict).toBe("SHIP");
  expect(result?.preview).toBe("SHIP at 1cb6e9091234 · no findings");
});
