// l10n-allow-file: sample machine facts and a sample code for the gallery, the mock host and tests.
// Sample Pair Another Machine statuses: the mock invite (code 7KQ4M-X2D9P, ten minutes from `now`)
// and the arrived machine Add Server's preview reads.
import type { PairInviteApprover, PairInviteStatus, PairingCandidate } from "./types";

/** A sample QR (a small fixed pattern, one pixel per module); the app sends the real code's. */
export const SAMPLE_QR =
  "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAADUAAAA1AQAAAADJnZ7dAAABp0lEQVR42mP4DwY/GGD0gYBG66UXJBjuB+gx1ojfYLgYIRx3aEoEw8UyG5XYLUA6zIhV60sEw/2iJ2Ury28wHAgFggAJhv8P35Xujv/BcIPtBkvuWwmGe7tWPAh0qGC4YFz4a8qFGwzfd7tYHY+MYHjr4OrjuhLI7/+4zUPhB8O11Hrf8xYzGL5N63UUYLNguFj8+bQvjwTDzaZnHGaTfjAcCzbwZD8pwfBvzbbnzrN2MHxRyLlTmT6D4eMDF7N0RwuGM+KdbIcbZzC8vfm89FJMBcNJ577QgyFA/j2GYu+YHww/pNrYvzRKMPy6unnRtscRDNfNthy7YhzB8PWhpDTLaQuGNwLKgYJHIxhOnnvn17biB8M/h+T1J5dEMPy90uH3xiWC4Zu3lYl28Q2Gy+uXm/lYSTBcCTi39ur+GwyH13CyclZYMLwzU565Vj2C4fGCN0ZmuysYjqusZ5rCAAyPM6dKU+5UMBwI3ht6Y8oNhvuBJwvMYmcwXAz6xlp4cAfDxWCel6J2wPDMmnj3wtMdDPcL4xzMr0swHIg8rigw+wYDWrwAAHFsz/5q78d0AAAAAElFTkSuQmCC";

export const SAMPLE_CANDIDATE: PairingCandidate = {
  code: "H7K2M9QX",
  name: "build-box",
  os: "Ubuntu 24.04",
  version: "cmux 0.67.0",
  region: "DE",
  words: ["amber", "harbor", "violet", "ladder"],
};

const IDLE_APPROVER: PairInviteApprover = { step: "enterCode", canApprove: false, runChief: false };

/** The invite as the app shows it, expiring `minutesLeft` after `now`. */
export function showingStatus(now: number, minutesLeft = 10): PairInviteStatus {
  return {
    session: 1,
    mint: "ready",
    frames: [{ t: "pending" }],
    approver: IDLE_APPROVER,
    invite: {
      code: "7KQ4M-X2D9P",
      line: "cmux pair 7KQ4M-X2D9P",
      installLine: "curl -fsSL https://cmux.com/tui/install-static.sh | sh && ~/.cmux/bin/cmux pair 7KQ4M-X2D9P",
      qr: SAMPLE_QR,
      expiresAt: now + minutesLeft * 60_000,
    },
  };
}

/** A machine used the code; Add Server's approver is at `approver`. */
export function arrivedStatus(now: number, approver: Partial<PairInviteApprover> = {}): PairInviteStatus {
  return {
    ...showingStatus(now),
    frames: [{ t: "pending" }, { t: "arrived", code: SAMPLE_CANDIDATE.code }],
    approver: { step: "review", candidate: SAMPLE_CANDIDATE, canApprove: true, runChief: false, ...approver },
  };
}

export function mintingStatus(): PairInviteStatus {
  return { session: 1, mint: "minting", frames: [], approver: IDLE_APPROVER };
}

export function endedStatus(now: number, frame: "voided" | "expired" | "lost"): PairInviteStatus {
  return { ...showingStatus(now), frames: [{ t: "pending" }, { t: frame }] };
}

export function signedOutStatus(): PairInviteStatus {
  return { session: 1, mint: "failed", failure: { signedOut: true }, frames: [], approver: IDLE_APPROVER };
}
