// The Chief chat's people for the shared chat faces (Faces.tsx), read from Home's own model
// (pages/home-channels/types.ts): the same header faces as a regular
// agent chat, one component, one adapter per source (participants.ts reads acpmux's records; this
// reads Home's). Leo, 2026-10-26: "also chief chats we need multiplayer".
//
// Home draws each message's author itself (its avatar and name). It has members, typing
// (`conversation-typing {conversation, participant, on}`, store.ts `snapshot.typing`) and who has
// the chat open (the owner's `conversation-presence`, store.ts `snapshot.viewing`). Whoever types
// counts as here too.
import type { HomeParticipant } from "../../../pages/home-channels/types";
import { participant, type ChatPresence, type Participant } from "./participants";

/// A Home participant as a face: people only; a Chief or an agent keeps Home's own mark.
export function chiefParticipant(person: HomeParticipant | undefined): Participant | undefined {
  if (!person || person.kind !== "human") return undefined;
  return participant(person.id, person.name);
}

/// The chat's presence from Home: `members` the conversation's own participants, `typing` the
/// participant ids typing now (store.ts), `viewing` the ids its owner says have it open, when it
/// says. Only members draw; the reader and agents are left out.
export function chiefPresence(
  members: ReadonlyMap<string, HomeParticipant>,
  me: string,
  typing: readonly string[],
  viewing: readonly string[] = [],
): ChatPresence {
  const pick = (ids: readonly string[]) => {
    const seen = new Set<string>();
    const out: Participant[] = [];
    for (const id of ids) {
      if (id === me || seen.has(id)) continue;
      seen.add(id);
      const person = chiefParticipant(members.get(id));
      if (person) out.push(person);
    }
    return out;
  };
  const typers = pick(typing);
  const here = pick([...viewing, ...typing]);
  return { viewing: here, typing: typers };
}
