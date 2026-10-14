// A Chief's live state for its row and header: working (writing a reply or typing, in which
// conversation), waiting for me (its last message in our direct conversation asks me something and
// I have not answered), or idle.
// One function, so the owner's own agent state (when the daemon reports it) replaces the rule here.
import type { HomeConversation, HomeParticipant } from "./types";

export type ChiefState =
  | { kind: "working"; conversation: string }
  | { kind: "waiting" }
  | { kind: "idle" };

/** The Chief of a direct conversation with one Chief, else undefined. */
export function chiefOf(conversation: HomeConversation, me: string | undefined): HomeParticipant | undefined {
  if (conversation.kind !== "chief") return undefined;
  return conversation.participants.find((p) => p.id !== me && p.chief);
}

export function chiefState(
  conversation: HomeConversation,
  me: string | undefined,
  busy: ReadonlyMap<string, string>,
): ChiefState | undefined {
  const chief = chiefOf(conversation, me);
  if (!chief) return undefined;
  const where = busy.get(chief.id);
  if (where) return { kind: "working", conversation: where };
  if (conversation.lastAuthor === chief.id && conversation.lastText?.includes("?")) return { kind: "waiting" };
  return { kind: "idle" };
}
