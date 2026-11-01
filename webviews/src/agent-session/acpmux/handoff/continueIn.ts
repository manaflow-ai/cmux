import { continueTargets } from "../cmuxCommands";
import type { AcpmuxSnapshot } from "../model";

/// The chat's own continuation waits for its review in this tab: a draft or starting handoff that
/// targets this chat and has no receipt yet.
export function reviewingHandoff(snapshot: AcpmuxSnapshot): boolean {
  const handoff = snapshot.handoff?.record;
  return (
    !!handoff &&
    handoff.target.sessionId === snapshot.sessionId &&
    ["draft", "starting"].includes(handoff.state) &&
    !snapshot.handoff?.receipt
  );
}

/// Continue In… can start now, wherever it is offered (the chat menu, `/continue`, the composer's
/// Fork to): the host can hand off and its handoff is ready and idle, no turn or queue runs, no
/// review is open, and another harness in the chat's catalog can take the chat.
export function canContinueIn(snapshot: AcpmuxSnapshot): boolean {
  return (
    !!snapshot.canHandoff &&
    !!snapshot.handoff?.ready &&
    !snapshot.isWorking &&
    !snapshot.queue.length &&
    !snapshot.handoff?.busy &&
    !reviewingHandoff(snapshot) &&
    continueTargets(snapshot.catalog, snapshot.summary?.harness, snapshot.summary?.family).length > 0
  );
}
