// The Pair Another Machine card's state, derived from the host's status (types.ts): the phase the
// socket's frames lead to, the step the card shows, its buttons and the countdown. Pure: the card
// and its tests read it the same way.
import type { PairInviteApprover, PairInviteFrame, PairInviteShown, PairInviteStatus, PairingCandidate } from "./types";

export type Phase =
  | { kind: "minting" }
  /** The invite shows; no machine has used it yet. */
  | { kind: "waiting"; invite: PairInviteShown }
  /** A machine used it: its pending server pairing has `code` (the approver previews it). */
  | { kind: "arrived"; invite: PairInviteShown; code: string }
  /** The socket said the machine is enrolled. */
  | { kind: "paired"; host: string }
  /** A second machine used the code: nothing pairs with it. */
  | { kind: "voided" }
  | { kind: "expired" }
  /** The socket closed before the invite ended. */
  | { kind: "lost" }
  | { kind: "signedOut" }
  | { kind: "failed"; text: string };

export type Step =
  | { kind: "minting" }
  | { kind: "showing"; invite: PairInviteShown }
  | { kind: "lookingUp"; invite: PairInviteShown }
  | { kind: "review"; invite: PairInviteShown; candidate: PairingCandidate }
  | { kind: "approving"; invite: PairInviteShown; candidate: PairingCandidate }
  | { kind: "approveFailed"; invite: PairInviteShown; candidate: PairingCandidate; reject: string }
  /** Enrolled: the machine's name (or the host id when the approve was not this card's). */
  | { kind: "paired"; name: string }
  | { kind: "voided" }
  | { kind: "expired" }
  | { kind: "lost" }
  | { kind: "signedOut" }
  | { kind: "failed"; text: string };

export type Action = "copyCode" | "copyLine" | "copyInstallLine" | "confirm" | "retry" | "newCode" | "done" | "cancel";

/** A footer button: its action and the key that presses it. Confirm and Try Again show as the default
 * button, but only the person's click presses them, never a key. */
export interface FooterButton {
  action: Action;
  key: "return" | "escape" | null;
}

/** Whether only the person's own click on the control answers it. */
export function isClickOnly(action: Action): boolean {
  return action === "confirm" || action === "retry";
}

/** One socket frame applied to the phase. A frame that comes after the invite ended changes nothing. */
export function receive(phase: Phase, frame: PairInviteFrame): Phase {
  switch (frame.t) {
    case "arrived":
      if (phase.kind === "waiting") return { kind: "arrived", invite: phase.invite, code: frame.code };
      if (phase.kind === "arrived" && phase.code !== frame.code) return { ...phase, code: frame.code };
      return phase;
    case "paired":
      return phase.kind === "waiting" || phase.kind === "arrived" ? { kind: "paired", host: frame.host } : phase;
    case "voided":
      return phase.kind === "waiting" || phase.kind === "arrived" ? { kind: "voided" } : phase;
    case "expired":
    case "lost":
      // The machine's own pairing outlives the invite: an arrived machine's Confirm still answers.
      return phase.kind === "waiting" ? { kind: frame.t } : phase;
    case "pending":
      return phase;
  }
}

/** The phase of `status` at `now` (Unix ms): the mint, then every frame, then the countdown. */
export function phaseOf(status: PairInviteStatus, now: number): Phase {
  if (status.mint === "failed") {
    return status.failure?.signedOut ? { kind: "signedOut" } : { kind: "failed", text: status.failure?.text ?? "" };
  }
  const invite = status.invite;
  if (status.mint !== "ready" || !invite) return { kind: "minting" };
  let phase: Phase = { kind: "waiting", invite };
  for (const frame of status.frames) phase = receive(phase, frame);
  if (phase.kind === "waiting" && now >= invite.expiresAt) return { kind: "expired" };
  return phase;
}

/** What the card shows: the phase, and once a machine arrived, Add Server's step for its code. */
export function stepOf(phase: Phase, approver: PairInviteApprover): Step {
  switch (phase.kind) {
    case "waiting":
      return { kind: "showing", invite: phase.invite };
    case "arrived": {
      const { invite, code } = phase;
      const candidate = approver.candidate;
      const ours = candidate !== undefined && candidate.code === code;
      if (approver.step === "added") return { kind: "paired", name: approver.added ?? "" };
      if (approver.step === "review" && ours) return { kind: "review", invite, candidate };
      if (approver.step === "approving" && ours) return { kind: "approving", invite, candidate };
      if (approver.step === "approveFailed" && ours) {
        return { kind: "approveFailed", invite, candidate, reject: approver.reject ?? "" };
      }
      if (approver.step === "codeRefused") return { kind: "failed", text: approver.reject ?? "" };
      return { kind: "lookingUp", invite };
    }
    case "paired":
      return { kind: "paired", name: approver.lastApproved ?? phase.host };
    default:
      return phase;
  }
}

/** The footer for `step`. */
export function buttonsOf(step: Step): FooterButton[] {
  const cancel: FooterButton = { action: "cancel", key: "escape" };
  switch (step.kind) {
    case "minting":
    case "showing":
    case "lookingUp":
    case "signedOut":
      return [cancel];
    case "review":
    case "approving":
      return [cancel, { action: "confirm", key: "return" }];
    case "approveFailed":
      return [cancel, { action: "retry", key: "return" }];
    case "paired":
      return [{ action: "done", key: "return" }];
    case "voided":
    case "expired":
    case "lost":
    case "failed":
      return [cancel, { action: "newCode", key: "return" }];
  }
}

/** Whether Confirm can go: the arrived machine's facts and words show, and no approve is in flight. */
export function canConfirm(step: Step, approver: PairInviteApprover): boolean {
  return (step.kind === "review" || step.kind === "approveFailed") && approver.canApprove;
}

/** Whether `action`'s button can be pressed now. */
export function isEnabled(action: Action, step: Step, approver: PairInviteApprover): boolean {
  return isClickOnly(action) ? canConfirm(step, approver) : true;
}

/** Seconds left on `invite` at `now`, rounded up, never below zero. */
export function secondsLeft(invite: PairInviteShown, now: number): number {
  return Math.max(0, Math.ceil((invite.expiresAt - now) / 1000));
}

/** `9:41`. */
export function clock(seconds: number): string {
  return `${Math.floor(seconds / 60)}:${String(seconds % 60).padStart(2, "0")}`;
}

/** The countdown turns to the attention color in its last minute. */
export function isUrgent(seconds: number): boolean {
  return seconds < 60;
}
