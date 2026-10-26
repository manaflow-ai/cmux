// The Chief chat's people for the shared chat faces (Faces.tsx), read from Home's own model
// (pages/home-channels/types.ts): the same author chip, header faces and typing line as a regular
// agent chat, one component, one adapter per source (participants.ts reads acpmux's records; this
// reads Home's). Leo, 2026-10-26: "also chief chats we need multiplayer".
//
// Home has members (`HomeConversation.participants`), authors (`HomeMessage.author`) and typing
// (`conversation-typing {conversation, participant, on}`, store.ts `snapshot.typing`), but not who
// has the chat open: until the owner sends that (hq plans/cmux-next/chat-multiplayer/DESIGN.md
// "Asks for Lawrence"), `viewing` is whoever types, and a caller that knows more passes it.
import type { HomeMessage, HomeParticipant } from "../../../pages/home-channels/types";
import type { ChatPresence, Participant } from "./participants";

/// A Home participant as a face: people only; a Chief or an agent keeps Home's own mark.
export function chiefParticipant(person: HomeParticipant | undefined): Participant | undefined {
  if (!person || person.kind !== "human") return undefined;
  return { id: person.id, name: person.name.trim() || person.id };
}

/// Who wrote `message`, when it is another person (the reader's own and an agent's draw no chip).
export function chiefAuthor(
  message: Pick<HomeMessage, "author">,
  people: ReadonlyMap<string, HomeParticipant>,
  me: string,
): Participant | undefined {
  if (message.author === me) return undefined;
  return chiefParticipant(people.get(message.author));
}

/// The chat's presence from Home: `typing` the participant ids typing now (store.ts), `viewing`
/// the ids its owner says have it open, when it says. The reader and agents are left out.
export function chiefPresence(
  people: ReadonlyMap<string, HomeParticipant>,
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
      const person = chiefParticipant(people.get(id));
      if (person) out.push(person);
    }
    return out;
  };
  const typers = pick(typing);
  const here = pick([...viewing, ...typing]);
  return { viewing: here, typing: typers };
}
