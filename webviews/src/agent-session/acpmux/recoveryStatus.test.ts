// The pane's reading of acpmux's recovery rows (recoveryStatus.ts).
import { expect, test } from "bun:test";
import { recoveryStatus } from "./recoveryStatus";

const resumed = { state: "resumed", nextAction: "none", continuationPromptId: "p1~resume-1" };

test("a resumed turn is queued while its continuation waits, delivered once it runs, and gone after", () => {
  expect(
    recoveryStatus({ lastTurn: { restartOutcome: resumed }, queue: [{ promptId: "p1~resume-1" }] })?.restartOutcome
      ?.delivery,
  ).toBe("queued");
  expect(
    recoveryStatus({ lastTurn: { restartOutcome: resumed }, turn: { promptId: "p1~resume-1" } })?.restartOutcome
      ?.delivery,
  ).toBe("delivered");
  expect(recoveryStatus({ lastTurn: { restartOutcome: resumed } })).toBeUndefined();
});

test("a waiting outcome speaks until the chat runs a turn again", () => {
  const lastTurn = { restartOutcome: { state: "waiting_for_user", nextAction: "send_again", why: "hidden_context" } };
  expect(recoveryStatus({ lastTurn })?.restartOutcome?.nextAction).toBe("send_again");
  expect(recoveryStatus({ lastTurn, turn: { promptId: "p2" } })).toBeUndefined();
});

test("an offered or armed resume needs a reported reset; only unknown_reset goes without one", () => {
  expect(recoveryStatus({ resumeAtReset: { state: "offered", turnId: "t" } })).toBeUndefined();
  expect(recoveryStatus({ resumeAtReset: { state: "armed", turnId: "t", resetsAt: 5 } })?.resumeAtReset?.resetsAt).toBe(
    5,
  );
  expect(
    recoveryStatus({ resumeAtReset: { state: "unknown_reset", turnId: "t", resetsAt: 5 } })?.resumeAtReset,
  ).toEqual({ state: "unknown_reset", turnId: "t" });
  expect(recoveryStatus({ resumeAtReset: { state: "other", turnId: "t" } })).toBeUndefined();
});
