// The label the lane-gh broker puts around a lane VM's message (leo-workspace
// machines/lane-gh-broker.json, action send): `[message N from VM/LANE (an agent, not Leo), relayed
// by the lane-gh broker; its text ends at "[end of message N]"]`, the text, then `[end of message
// N]`, with a fresh nonce N. The label is for the agent, which must not read a lane's words as
// Leo's; the transcript draws the message as its sender's card and leaves the label out (Leo,
// 2026-11-05: "It probably shouldn't be displaying it in that kind of raw way. Like we don't need to
// render it like this, in either here nor the iOS thing."). The prompt the agent got is unchanged
// (`raw`). The iOS chat reads the same form (CmuxMobileAgentChat RelayEnvelope.swift).

export type RelayEnvelope = {
  /// The broker's nonce for this message.
  id: string;
  /// The sending lane, as the broker names it: `VM/LANE`.
  sender: string;
  /// Who relayed it (`the lane-gh broker`).
  relay: string;
  /// The message as the lane wrote it.
  body: string;
};

const HEAD =
  /^\[message ([A-Za-z0-9_-]{4,64}) from ([^\n()[\]]{1,160}?) \(an agent, not Leo\), relayed by ([^\n;[\]]{1,80}); its text ends at "\[end of message \1\]"\]$/;
/// The head alone, at the start of a one-line preview (an inbox thread's).
const HEAD_PREFIX =
  /^\[message ([A-Za-z0-9_-]{4,64}) from [^\n()[\]]{1,160}? \(an agent, not Leo\), relayed by [^\n;[\]]{1,80}; its text ends at "\[end of message \1\]"\]\s*/;

/// The message in `text` when the whole of it is one broker label, closed by its own nonce on the
/// last line; undefined for anything else, which then reads as written. A closing line inside the
/// text never ends it: only the last line does.
export function relayEnvelope(text: string): RelayEnvelope | undefined {
  const trimmed = text.trim();
  const headEnd = trimmed.indexOf("\n");
  if (headEnd < 0) return undefined;
  const head = HEAD.exec(trimmed.slice(0, headEnd).trimEnd());
  if (!head) return undefined;
  const id = head[1]!;
  const closing = `[end of message ${id}]`;
  if (!trimmed.endsWith(closing)) return undefined;
  const bodyEnd = trimmed.length - closing.length;
  // The closing marker is a line of its own; one written inline is the body's own text.
  if (bodyEnd <= headEnd || trimmed[bodyEnd - 1] !== "\n") return undefined;
  return { id, sender: head[2]!.trim(), relay: head[3]!.trim(), body: trimmed.slice(headEnd + 1, bodyEnd).trim() };
}

/// `text` without a broker label around it: the message alone, else `text` as written.
export function withoutRelayEnvelope(text: string): string {
  return relayEnvelope(text)?.body ?? text;
}

/// A one-line preview without the broker's head before the message's first words, nor its
/// closing line after them (a preview of a short message holds both).
export function withoutRelayHead(preview: string): string {
  const head = HEAD_PREFIX.exec(preview);
  if (!head) return preview;
  const rest = preview.slice(head[0].length).trim();
  const closing = `[end of message ${head[1]}]`;
  return rest.endsWith(closing) ? rest.slice(0, -closing.length).trim() : rest;
}
