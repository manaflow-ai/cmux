// What acpmux did, or can do, about the chat's last turn (RecoveryNotice.tsx). acpmux decides it:
// `summary.resumeAtReset` (hub/auto_resume/at_reset.rs) and `lastTurn.restartOutcome`
// (hub/restart_outcome.rs). The pane only reads them, and tells a continuation still queued from
// one the agent has started by the chat's queue and running turn.

export type ResumeAtResetRow = {
  state: "offered" | "armed" | "unknown_reset";
  turnId: string;
  /** The provider's reported reset (Unix ms); absent for `unknown_reset`. */
  resetsAt?: number;
};

export type RestartOutcomeRow = {
  state: "resumed" | "waiting_for_user" | "unable_to_resume";
  nextAction: "none" | "send_again" | "review_then_send" | "retry";
  why?: string;
  continuationPromptId?: string;
  unfinishedTools?: string[];
  toolsOmitted?: boolean;
};

export type RecoveryStatus = {
  resumeAtReset?: ResumeAtResetRow;
  /** Present only while it still speaks for the chat (see `recoveryStatus`). */
  restartOutcome?: RestartOutcomeRow & { delivery?: "queued" | "delivered" };
};

type Summary = {
  resumeAtReset?: unknown;
  lastTurn?: unknown;
  turn?: { promptId?: unknown } | null;
  queue?: readonly { promptId?: unknown }[];
};

function record(value: unknown): Record<string, unknown> | undefined {
  return value && typeof value === "object" && !Array.isArray(value) ? (value as Record<string, unknown>) : undefined;
}

const RESET_STATES = new Set(["offered", "armed", "unknown_reset"]);
const OUTCOME_STATES = new Set(["resumed", "waiting_for_user", "unable_to_resume"]);
const NEXT_ACTIONS = new Set(["none", "send_again", "review_then_send", "retry"]);

function readResumeAtReset(value: unknown): ResumeAtResetRow | undefined {
  const row = record(value);
  if (!row || typeof row.state !== "string" || !RESET_STATES.has(row.state) || typeof row.turnId !== "string")
    return undefined;
  const resetsAt = typeof row.resetsAt === "number" && Number.isFinite(row.resetsAt) ? row.resetsAt : undefined;
  // An offer or arm with no reset would be a guessed countdown: only unknown_reset goes without.
  if (row.state !== "unknown_reset" && resetsAt === undefined) return undefined;
  return {
    state: row.state as ResumeAtResetRow["state"],
    turnId: row.turnId,
    ...(row.state !== "unknown_reset" && resetsAt !== undefined ? { resetsAt } : {}),
  };
}

function readRestartOutcome(value: unknown): RestartOutcomeRow | undefined {
  const row = record(value);
  if (!row || typeof row.state !== "string" || !OUTCOME_STATES.has(row.state)) return undefined;
  const next = typeof row.nextAction === "string" && NEXT_ACTIONS.has(row.nextAction) ? row.nextAction : "none";
  const tools = Array.isArray(row.unfinishedTools)
    ? row.unfinishedTools.filter((tool): tool is string => typeof tool === "string" && tool.length > 0)
    : [];
  return {
    state: row.state as RestartOutcomeRow["state"],
    nextAction: next as RestartOutcomeRow["nextAction"],
    ...(typeof row.why === "string" ? { why: row.why } : {}),
    ...(typeof row.continuationPromptId === "string" ? { continuationPromptId: row.continuationPromptId } : {}),
    ...(tools.length > 0 ? { unfinishedTools: tools } : {}),
    ...(row.toolsOmitted === true ? { toolsOmitted: true } : {}),
  };
}

/// The chat's recovery line, or undefined for none. A resumed turn speaks only while its
/// continuation is queued or running: once it ends, it is the chat's last turn and says so itself.
/// Any other outcome speaks until the chat runs a turn again.
export function recoveryStatus(summary: Summary | undefined): RecoveryStatus | undefined {
  if (!summary) return undefined;
  const resumeAtReset = readResumeAtReset(summary.resumeAtReset);
  const outcome = readRestartOutcome(record(summary.lastTurn)?.restartOutcome);
  const running = typeof summary.turn?.promptId === "string" ? summary.turn.promptId : undefined;
  let restartOutcome: RecoveryStatus["restartOutcome"];
  if (outcome?.state === "resumed") {
    const id = outcome.continuationPromptId;
    const delivery =
      id !== undefined && running === id
        ? "delivered"
        : id !== undefined && (summary.queue ?? []).some((queued) => queued.promptId === id)
          ? "queued"
          : undefined;
    restartOutcome = delivery ? { ...outcome, delivery } : undefined;
  } else if (outcome && running === undefined) {
    restartOutcome = outcome;
  }
  return resumeAtReset || restartOutcome
    ? { ...(resumeAtReset ? { resumeAtReset } : {}), ...(restartOutcome ? { restartOutcome } : {}) }
    : undefined;
}

/// acpmux serves the one-shot resume at the reset (`_acpmux/retry {atReset}`, capabilities.rs).
export const RESUME_AT_RESET = "resume-at-reset-v1";
