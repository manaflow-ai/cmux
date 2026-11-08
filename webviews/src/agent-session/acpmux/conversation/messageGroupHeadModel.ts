import type { IncomingMessage } from "./incomingMessage";

/// The one sender of a group's messages, the one that best names its session and harness, or
/// nothing when two or more sessions sent (the head then draws the messages glyph). A sender is its
/// session when one is known, else what its chat is asked for by (`lookup`), else its name, as
/// pendingMessages.ts `bySender` groups them; two sessions that share a name are two senders, and
/// so are two harnesses (cmux#30821).
export function groupSender(messages: readonly (IncomingMessage | undefined)[]): IncomingMessage | undefined {
  const known = messages.filter((message): message is IncomingMessage => Boolean(message));
  const senders = new Set(
    known.map((message) =>
      message.sessionId
        ? `session:${message.sessionId}`
        : message.lookup
          ? `lookup:${message.lookup}`
          : `name:${message.name}`,
    ),
  );
  if (senders.size !== 1) return undefined;
  if (new Set(known.flatMap((message) => (message.harness ? [message.harness] : []))).size > 1) return undefined;
  return (
    [...known].reverse().find((message) => message.harness) ??
    [...known].reverse().find((message) => message.sessionId) ??
    known.at(-1)
  );
}
