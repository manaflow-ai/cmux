/**
 * Hints the Cloud machine as soon as a person starts a prompt.
 *
 * This is deliberately a hint, rather than part of delivery. The platform's predictive wake
 * policy may ignore it (the machine may already be live, or the hint may race a send), and a
 * rejected native request must never hold the draft or change the send path.
 */

export const CLOUD_TYPING_PREWARM_REFRESH_MS = 2_000;

export type CloudTypingPrewarmPort = { prewarm(machineID: string): boolean | Promise<boolean> };

export type CloudTypingTarget = { machineID: string; sessionID?: string };

const sameTarget = (left: CloudTypingTarget | undefined, right: CloudTypingTarget) =>
  left?.machineID === right.machineID && left?.sessionID === right.sessionID;

export class CloudTypingPrewarm {
  private last?: { target: CloudTypingTarget; at: number; pending: boolean };

  constructor(
    private readonly port: CloudTypingPrewarmPort,
    private readonly now: () => number = Date.now,
  ) {}

  /** Hint once for the first non-empty edit, then refresh only after the short dedupe window. */
  typed(text: string, target: CloudTypingTarget | undefined): void {
    if (!text.trim() || !target?.machineID) return;
    const at = this.now();
    if (
      this.last &&
      sameTarget(this.last.target, target) &&
      (this.last.pending || at - this.last.at < CLOUD_TYPING_PREWARM_REFRESH_MS)
    ) return;
    const attempt = { target, at, pending: true };
    this.last = attempt;
    const settle = (accepted: boolean) => {
      // A completion from an old chat or before reset must not replace the current target.
      if (this.last !== attempt) return;
      if (accepted) attempt.pending = false;
      else this.last = undefined;
    };
    try {
      const accepted = this.port.prewarm(target.machineID);
      if (typeof accepted === "boolean") settle(accepted);
      else void accepted.then(settle, () => settle(false));
    } catch {
      // A rejected hint may race inventory loading. Allow the next edit to try again.
      settle(false);
    }
  }

  /** Clear a previous target when the pane leaves its chat. */
  reset(): void {
    this.last = undefined;
  }
}
