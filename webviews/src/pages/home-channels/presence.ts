// What a Chief is doing now, for its row in the conversation list and its conversation header:
// working (a running reply or typing anywhere), waiting for me (its last message in our direct
// conversation asks me something that is still open) or idle. The page derives it from what the
// daemon already sends (`conversation-draft`, `conversation-typing`, the summary's last message).
// PLACEHOLDER: when the daemon projects the Chief's session state (home.* projection, DESIGN.md G8)
// this one function reads that field instead; nothing else changes.
import type { HomeConversation, HomeParticipant } from "./types";

export type ChiefState = "working" | "waiting" | "idle";

/** Live activity by participant: the conversation it is writing in (typing or a running reply). */
export type Activity = ReadonlyMap<string, string>;

export interface ChiefPresence {
  state: ChiefState;
  /** Where it works, when that is another conversation than ours. */
  where?: string;
}

/** The other member of a direct conversation, when it is a Chief. */
export function chiefOf(conversation: HomeConversation, me: string | undefined): HomeParticipant | undefined {
  if (conversation.kind !== "chief") return undefined;
  const other = conversation.participants.find((p) => p.id !== me);
  return other?.chief ? other : undefined;
}

export function chiefPresence(
  conversation: HomeConversation,
  me: string | undefined,
  activity: Activity,
): ChiefPresence | undefined {
  const chief = chiefOf(conversation, me);
  if (!chief) return undefined;
  const writingIn = activity.get(chief.id);
  if (writingIn !== undefined)
    return writingIn === conversation.id ? { state: "working" } : { state: "working", where: writingIn };
  if (conversation.lastAuthor === chief.id && conversation.lastAsks) return { state: "waiting" };
  return { state: "idle" };
}
