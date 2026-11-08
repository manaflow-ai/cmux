import { afterEach, expect, test } from "bun:test";
import type { HeaderPullRequest } from "../header/headerState";
import {
  endFinishMoment,
  FINISH_MS,
  finishMoment,
  isFinishedTurnRow,
  LONG_TURN_MS,
  longTurnEnded,
  pullRequestFinish,
  startFinishMoment,
} from "./finishMoments";

afterEach(() => endFinishMoment());

const pr = (state: string, checks: string, url = "https://github.com/o/r/pull/1"): HeaderPullRequest => ({
  url,
  number: 1,
  title: "t",
  state,
  review: "",
  mergeable: "",
  checks: { state: checks, passed: 0, total: 0 },
  checkList: [],
});

test("a turn of the same chat that ran 30 s or more ends with its start; a shorter one ends quietly", () => {
  const start = 1_000_000;
  const running = { session: "s", working: true, turnStartedAtMs: start };
  expect(longTurnEnded(running, { session: "s", working: false }, start + LONG_TURN_MS)).toBe(start);
  expect(longTurnEnded(running, { session: "s", working: false }, start + LONG_TURN_MS - 1)).toBeUndefined();
  // Still running, another chat, or a start the page never saw: no moment.
  expect(longTurnEnded(running, running, start + 60_000)).toBeUndefined();
  expect(longTurnEnded(running, { session: "t", working: false }, start + 60_000)).toBeUndefined();
  expect(
    longTurnEnded({ session: "s", working: true }, { session: "s", working: false }, start + 60_000),
  ).toBeUndefined();
});

test("a peer's turn is timed in this computer's clock", () => {
  // The session's clock runs 40 s behind this computer's: a turn it started at `start` began 40 s later here.
  const start = 1_000_000;
  const last = { session: "s", working: true, turnStartedAtMs: start };
  const next = { session: "s", working: false };
  expect(longTurnEnded(last, next, start + 40_000 + 20_000, 40_000)).toBeUndefined();
  expect(longTurnEnded(last, next, start + 40_000 + LONG_TURN_MS, 40_000)).toBe(start);
});

test("a merge and green checks are transitions of the same pull request, never its first read", () => {
  expect(pullRequestFinish(pr("open", "pending"), pr("merged", "passing"))).toBe("merged");
  expect(pullRequestFinish(pr("merged", "passing"), pr("merged", "passing"))).toBeUndefined();
  expect(pullRequestFinish(pr("open", "pending"), pr("open", "passing"))).toBe("ci");
  expect(pullRequestFinish(pr("draft", "failing"), pr("draft", "passing"))).toBe("ci");
  // Passing already, no checks, a closed pull request, a first read, another link: nothing.
  expect(pullRequestFinish(pr("open", "passing"), pr("open", "passing"))).toBeUndefined();
  expect(pullRequestFinish(pr("open", "none"), pr("open", "passing"))).toBeUndefined();
  expect(pullRequestFinish(pr("open", "pending"), pr("closed", "passing"))).toBeUndefined();
  expect(pullRequestFinish(undefined, pr("merged", "passing"))).toBeUndefined();
  expect(
    pullRequestFinish(pr("open", "pending", "https://x/1"), pr("merged", "passing", "https://x/2")),
  ).toBeUndefined();
});

test("only the ended turn's own Worked for row shows the turn moment", () => {
  const moment = { kind: "turn" as const, id: 1, turnStartedAt: 500_000 };
  // Its prompt is a moment before the daemon's start; an older turn ended before it.
  expect(isFinishedTurnRow(moment, 499_400)).toBe(true);
  expect(isFinishedTurnRow(moment, 440_000)).toBe(false);
  expect(isFinishedTurnRow({ kind: "merged", id: 2 }, 499_400)).toBe(false);
  expect(isFinishedTurnRow(undefined, 499_400)).toBe(false);
});

test("a moment clears itself after its time; a hidden page gets none", async () => {
  expect(startFinishMoment({ kind: "turn", session: "s", turnStartedAt: 1 }, false)).toBe(false);
  expect(finishMoment()).toBeUndefined();
  expect(startFinishMoment({ kind: "turn", session: "s", turnStartedAt: 1 }, true)).toBe(true);
  expect(finishMoment()?.kind).toBe("turn");
  await new Promise((resolve) => setTimeout(resolve, FINISH_MS.turn + 30));
  expect(finishMoment()).toBeUndefined();
});

test("a merge outranks a turn's end; a newer moment replaces an equal or smaller one", () => {
  expect(startFinishMoment({ kind: "merged", url: "https://x/1" }, true)).toBe(true);
  expect(startFinishMoment({ kind: "turn", turnStartedAt: 1 }, true)).toBe(false);
  expect(startFinishMoment({ kind: "ci", url: "https://x/1" }, true)).toBe(false);
  expect(finishMoment()?.kind).toBe("merged");
  endFinishMoment();
  expect(startFinishMoment({ kind: "turn", turnStartedAt: 1 }, true)).toBe(true);
  const turn = finishMoment()!.id;
  expect(startFinishMoment({ kind: "ci", url: "https://x/1" }, true)).toBe(true);
  expect(finishMoment()?.kind).toBe("ci");
  expect(finishMoment()!.id).toBeGreaterThan(turn);
});
