// Pair Another Machine's state (ported from PairInviteFlowTests' card assertions): the invite shows
// with its countdown and only Cancel; an arrival hands off to Add Server's preview and offers Confirm,
// which no key presses; a second machine, the expiry or a lost socket each end the invite and offer
// New Code; an expiry after the machine arrived still lets the person confirm.
import { describe, expect, test } from "bun:test";
import {
  arrivedStatus,
  endedStatus,
  mintingStatus,
  showingStatus,
  signedOutStatus,
  SAMPLE_CANDIDATE,
} from "./fixtures";
import {
  buttonsOf,
  canConfirm,
  clock,
  isClickOnly,
  isUrgent,
  phaseOf,
  receive,
  secondsLeft,
  stepOf,
  type Phase,
} from "./model";
import type { PairInviteStatus } from "./types";

const NOW = 1_000_000_000;
const step = (status: PairInviteStatus, now = NOW) => stepOf(phaseOf(status, now), status.approver);
const actions = (status: PairInviteStatus, now = NOW) => buttonsOf(step(status, now)).map((button) => button.action);

describe("the invite", () => {
  test("a mint in flight shows the minting step with Cancel", () => {
    expect(step(mintingStatus()).kind).toBe("minting");
    expect(actions(mintingStatus())).toEqual(["cancel"]);
  });

  test("a minted invite shows its code, ten minutes and only Cancel; pending changes nothing", () => {
    const status = showingStatus(NOW);
    const shown = step(status);
    expect(shown.kind).toBe("showing");
    expect(shown.kind === "showing" && secondsLeft(shown.invite, NOW)).toBe(600);
    expect(actions(status)).toEqual(["cancel"]);
  });

  test("the countdown rounds up, reads m:ss and turns urgent in its last minute", () => {
    const invite = showingStatus(NOW).invite!;
    expect(secondsLeft(invite, invite.expiresAt - 29_500)).toBe(30);
    expect(clock(581)).toBe("9:41");
    expect(clock(30)).toBe("0:30");
    expect(isUrgent(59)).toBe(true);
    expect(isUrgent(60)).toBe(false);
  });

  test("the code expires at its time or at the Worker's close, and offers New Code", () => {
    const status = showingStatus(NOW);
    expect(step(status, status.invite!.expiresAt - 30_000).kind).toBe("showing");
    expect(step(status, status.invite!.expiresAt).kind).toBe("expired");
    expect(actions(status, status.invite!.expiresAt)).toEqual(["cancel", "newCode"]);
    expect(step(endedStatus(NOW, "expired")).kind).toBe("expired");
  });

  test("a second machine voids the invite; a lost socket says so; both offer New Code", () => {
    expect(step(endedStatus(NOW, "voided")).kind).toBe("voided");
    expect(actions(endedStatus(NOW, "voided"))).toEqual(["cancel", "newCode"]);
    expect(step(endedStatus(NOW, "lost")).kind).toBe("lost");
    expect(actions(endedStatus(NOW, "lost"))).toEqual(["cancel", "newCode"]);
  });

  test("a refused mint says why: signed out, or the app's sentence", () => {
    expect(step(signedOutStatus()).kind).toBe("signedOut");
    expect(actions(signedOutStatus())).toEqual(["cancel"]);
    const refused: PairInviteStatus = {
      ...signedOutStatus(),
      failure: { text: "Could not make a pairing code: rate limited" },
    };
    expect(step(refused)).toEqual({ kind: "failed", text: "Could not make a pairing code: rate limited" });
    expect(actions(refused)).toEqual(["cancel", "newCode"]);
  });
});

describe("the arrived machine", () => {
  test("arrived runs Add Server's preview: looking up, then its facts with Cancel and Confirm", () => {
    const looking = arrivedStatus(NOW, { step: "lookingUp", candidate: undefined, canApprove: false });
    expect(step(looking).kind).toBe("lookingUp");
    expect(actions(looking)).toEqual(["cancel"]);
    const review = arrivedStatus(NOW);
    const shown = step(review);
    expect(shown.kind === "review" && shown.candidate).toEqual(SAMPLE_CANDIDATE);
    expect(actions(review)).toEqual(["cancel", "confirm"]);
    expect(canConfirm(shown, review.approver)).toBe(true);
  });

  test("the countdown is gone once a machine used the code: the arrival never expires on the page's clock", () => {
    const review = arrivedStatus(NOW);
    expect(step(review, review.invite!.expiresAt + 60_000).kind).toBe("review");
  });

  test("a preview for another code is not this machine's", () => {
    const other = arrivedStatus(NOW, { candidate: { ...SAMPLE_CANDIDATE, code: "OTHER123" } });
    expect(step(other).kind).toBe("lookingUp");
  });

  test("approving disables Confirm; a refused approve offers Try Again; added says paired with Done", () => {
    const approving = arrivedStatus(NOW, { step: "approving", canApprove: false });
    expect(step(approving).kind).toBe("approving");
    expect(canConfirm(step(approving), approving.approver)).toBe(false);
    const failed = arrivedStatus(NOW, { step: "approveFailed", reject: "The server went away." });
    expect(step(failed)).toMatchObject({ kind: "approveFailed", reject: "The server went away." });
    expect(actions(failed)).toEqual(["cancel", "retry"]);
    const added = arrivedStatus(NOW, { step: "added", added: "build box" });
    expect(step(added)).toEqual({ kind: "paired", name: "build box" });
    expect(actions(added)).toEqual(["done"]);
  });

  test("the socket's paired names the approved machine, else its host id", () => {
    const status = {
      ...arrivedStatus(NOW),
      frames: [...arrivedStatus(NOW).frames, { t: "paired" as const, host: "h_1" }],
    };
    expect(step(status)).toEqual({ kind: "paired", name: "h_1" });
    expect(step({ ...status, approver: { ...status.approver, lastApproved: "build box" } })).toEqual({
      kind: "paired",
      name: "build box",
    });
  });

  test("a refused preview says why", () => {
    const refused = arrivedStatus(NOW, { step: "codeRefused", reject: "That code expired." });
    expect(step(refused)).toEqual({ kind: "failed", text: "That code expired." });
  });

  test("voided after it arrived drops the machine; an expiry or a lost socket after it arrived keeps Confirm", () => {
    const arrived = arrivedStatus(NOW);
    expect(step({ ...arrived, frames: [...arrived.frames, { t: "voided" }] }).kind).toBe("voided");
    for (const t of ["expired", "lost"] as const) {
      const status = { ...arrived, frames: [...arrived.frames, { t }] };
      expect(step(status).kind).toBe("review");
      expect(canConfirm(step(status), status.approver)).toBe(true);
    }
  });

  test("SECURITY: Confirm and Try Again answer only a click, never the Return key", () => {
    expect(isClickOnly("confirm")).toBe(true);
    expect(isClickOnly("retry")).toBe(true);
    expect(isClickOnly("newCode")).toBe(false);
  });
});

describe("frames", () => {
  const invite = showingStatus(NOW).invite!;
  const waiting: Phase = { kind: "waiting", invite };

  test("a second arrival with a new code moves to it; the same code changes nothing", () => {
    const first = receive(waiting, { t: "arrived", code: "AAAAAAAA" });
    expect(receive(first, { t: "arrived", code: "AAAAAAAA" })).toBe(first);
    expect(receive(first, { t: "arrived", code: "BBBBBBBB" })).toEqual({ kind: "arrived", invite, code: "BBBBBBBB" });
  });

  test("a frame after the invite ended changes nothing", () => {
    const voided = receive(waiting, { t: "voided" });
    expect(receive(voided, { t: "arrived", code: "AAAAAAAA" })).toBe(voided);
    expect(receive(voided, { t: "paired", host: "h" })).toBe(voided);
  });
});
