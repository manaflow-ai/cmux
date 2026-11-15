import type { AcpmuxRow } from "../model";
import { agentKey } from "../../shared/agentKey";
import { isStopped } from "./turns";

export type InterruptedResumeState = {
  sessionId?: string;
  selectedSessionId?: string;
  drawnSessionId?: string;
  canResume: boolean;
  family?: string;
  rows: readonly AcpmuxRow[];
};

export function interruptedResumeTarget(state: InterruptedResumeState) {
  const { sessionId, selectedSessionId, drawnSessionId, canResume, rows } = state;
  if (!canResume || !sessionId || sessionId !== selectedSessionId || sessionId !== drawnSessionId) return undefined;
  let index = rows.length - 1;
  while (index >= 0 && rows[index]?.kind !== "turnSummary") index -= 1;
  const row = rows[index];
  if (!row || !row.resumable || !isStopped(row) || rows.slice(index + 1).some((row) => row.kind === "user"))
    return undefined;
  return { sessionId, rowId: row.id, family: state.family };
}

export type ResumeGesture = { promptId: string; ticket: Promise<string | undefined> };

export async function resumeInterrupted(
  owner: { sessionId: string; rowId: string },
  deps: {
    read: () => InterruptedResumeState;
    bind: () => ResumeGesture | undefined;
    emptyTurn: (
      sessionId: string,
      promptId: string,
      ticket: string | undefined,
      current: () => boolean,
    ) => Promise<unknown>;
    textTurn: (sessionId: string, gesture: ResumeGesture) => Promise<unknown>;
  },
): Promise<boolean> {
  const target = interruptedResumeTarget(deps.read());
  if (!target || target.sessionId !== owner.sessionId || target.rowId !== owner.rowId) return false;
  const gesture = deps.bind();
  if (!gesture) return false;
  const ticket = await gesture.ticket;
  const stillCurrent = () => {
    const current = interruptedResumeTarget(deps.read());
    return Boolean(
      current &&
      current.sessionId === target.sessionId &&
      current.rowId === target.rowId &&
      current.family === target.family,
    );
  };
  if (!stillCurrent()) return false;
  if (agentKey(target.family) === "codex")
    await deps.emptyTurn(target.sessionId, gesture.promptId, ticket, stillCurrent);
  else await deps.textTurn(target.sessionId, gesture);
  return true;
}

/// A pending continuation belongs to one chat; another stopped chat can resume independently.
export function interruptedResumeRunner(deps: Parameters<typeof resumeInterrupted>[1]) {
  const pending = new Set<string>();
  return async (owner: { sessionId: string; rowId: string }): Promise<boolean> => {
    if (pending.has(owner.sessionId)) return false;
    pending.add(owner.sessionId);
    try {
      return await resumeInterrupted(owner, deps);
    } finally {
      pending.delete(owner.sessionId);
    }
  };
}
