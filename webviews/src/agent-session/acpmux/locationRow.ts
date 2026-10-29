import type { AcpmuxSnapshot } from "./model";

type LocationState = Pick<AcpmuxSnapshot, "sessionId" | "summary" | "rows" | "queue" | "isWorking" | "canLoadOlder"> &
  Partial<Pick<AcpmuxSnapshot, "switching">>;

/// The chat has had its first send, by the session's own state: a turn acpmux recorded
/// (`turnCount`, counted when a prompt dispatches; older history to load counts as one), a user
/// prompt in the transcript that did not fail (the optimistic row of a prompt in flight included),
/// a turn running, or a prompt waiting in the queue (it runs where the chat is). A first send that
/// failed leaves only its failed row and no turn, so the chat is still new.
export function chatHasFirstSend(state: LocationState): boolean {
  const turns = state.summary?.turnCount ?? (state.canLoadOlder ? 1 : 0);
  return (
    turns > 0 ||
    state.isWorking ||
    state.queue.length > 0 ||
    state.rows.some((row) => row.kind === "user" && !row.failed)
  );
}

/// Whether the composer shows its visible location strip (folder · computer · branch,
/// ComposerContext.tsx): only on a new chat, before its first send. Not every harness can change
/// folder or machine mid-chat, and cmux does not, so a started chat has no visible strip at all. A
/// selected session whose summary has not arrived (a reopened chat loading) is not known to be
/// new and shows none, so a chat with history never flashes it.
export function showsLocationRow(state: LocationState): boolean {
  if (state.sessionId && state.summary?.sessionId !== state.sessionId && !state.switching) return false;
  if (state.sessionId && state.summary?.turnCount === undefined && !state.switching) return false;
  return !chatHasFirstSend(state);
}
