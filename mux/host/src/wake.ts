import { AGENT_MUX, type Message, type ParticipantId, type Summary } from "./conversation-types.ts";

// The wake rule (plans/cmux-next/home.md section 5). Pure.
//
// A human message wakes the mux when the mux participates and either the
// conversation has exactly one human and one agent (every human message), or
// the message mentions the mux, replies to one of the mux's messages, or the
// conversation is a DM with the mux.

export function wakes(
  summary: Summary,
  message: Message,
  isMuxMessage: (messageId: string) => boolean,
  mux: ParticipantId = AGENT_MUX,
): boolean {
  const author = summary.participants.find((p) => p.id === message.author);
  if (!author || author.kind !== "human" || message.author === mux) return false;
  // A paired device's message starts a remote-origin prompt chain
  // (server-remote-conversations.md section 6). Until that gate exists it never
  // wakes the mux: fail closed. Same rule as cmux_chief::rules::wakes.
  if (message.origin !== undefined || author.person !== undefined) return false;
  if (!summary.participants.some((p) => p.id === mux)) return false;
  if (message.retracted_at) return false;
  // Count persons, not participant ids: a paired device (`person`) is the same
  // human as its person, so pairing does not change the rule (decision D-C).
  const persons = new Set(summary.participants.filter((p) => p.kind === "human").map((p) => p.person ?? p.id)).size;
  const agents = summary.participants.filter((p) => p.kind === "agent").length;
  if (persons === 1 && agents === 1) return true;
  if (summary.id.startsWith("conv_dm_") && persons + agents === 2) return true;
  const mentioned = message.parts.some(
    (part) => part.type === "text" && (part.runs ?? []).some((run) => run.mention === mux),
  );
  if (mentioned) return true;
  return message.reply_to !== undefined && isMuxMessage(message.reply_to.message_id);
}
