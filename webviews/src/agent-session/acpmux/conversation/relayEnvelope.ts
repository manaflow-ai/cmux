// The label the lane-gh broker puts around a lane VM's message (leo-workspace
// machines/lane-gh-broker.json, action send): `[message N from VM/LANE (an agent, not Leo), relayed
// by the lane-gh broker; its text ends at "[end of message N]"]`, the text, then `[end of message
// N]`, with a fresh nonce N. The label is for the agent, which must not read a lane's words as
// Leo's; the transcript draws the message as its sender's card and leaves the label out (Leo,
// 2026-11-05: "It probably shouldn't be displaying it in that kind of raw way. Like we don't need to
// render it like this, in either here nor the iOS thing."). The prompt the agent got is unchanged
// (`raw`). The iOS chat reads the same form (CmuxMobileAgentChat RelayEnvelope.swift).

import { bareSender } from "./senderIdentity";

export type RelayEnvelope = {
  /// The broker's nonce for this message.
  id: string;
  /// The sending lane, as the broker names it: `VM/LANE`, bare of an older acpmux's suffix.
  sender: string;
  /// The label's sender carried that suffix: acpmux could not verify it (senderIdentity.ts).
  declared?: true;
  /// Who relayed it (`the lane-gh broker`).
  relay: string;
  /// The message as the lane wrote it.
  body: string;
};

// The sender may carry the suffix an older acpmux wrote into a name it could not verify
// (senderIdentity.ts): " (self-declared, unauthenticated)".
const HEAD =
  /^\[message ([A-Za-z0-9_-]{4,64}) from ([^\n()[\]]{1,160}?(?: \(self-declared, unauthenticated\))?) \(an agent, not Leo\), relayed by ([^\n;[\]]{1,80}); its text ends at "\[end of message \1\]"\]$/;
/// The head alone, at the start of a one-line preview (an inbox thread's).
const HEAD_PREFIX =
  /^\[message ([A-Za-z0-9_-]{4,64}) from [^\n()[\]]{1,160}?(?: \(self-declared, unauthenticated\))? \(an agent, not Leo\), relayed by [^\n;[\]]{1,80}; its text ends at "\[end of message \1\]"\]\s*/;

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
  const sender = bareSender(head[2]!);
  return {
    id,
    sender: sender.name,
    ...(sender.declared && { declared: true as const }),
    relay: head[3]!.trim(),
    body: trimmed.slice(headEnd + 1, bodyEnd).trim(),
  };
}

/// `text` without a broker label around it: the message alone, else `text` as written.
export function withoutRelayEnvelope(text: string): string {
  return relayEnvelope(text)?.body ?? text;
}

/// The start of a head, whether or not it closes after it.
const HEAD_START = /^\[message [A-Za-z0-9_-]{4,64} from /;

/// `text` after a whole head, without its closing line when it ends with one; undefined when no
/// whole head starts it.
function afterHead(text: string): string | undefined {
  const head = HEAD_PREFIX.exec(text);
  if (!head) return undefined;
  const rest = text.slice(head[0].length).trim();
  const closing = `[end of message ${head[1]}]`;
  return rest.endsWith(closing) ? rest.slice(0, -closing.length).trim() : rest;
}

/// A one-line preview without the broker's head before the message's first words, nor its
/// closing line after them (a preview of a short message holds both). A preview cut inside the head
/// (acpmux cuts a thread's preview at 120 characters, and a head runs longer: Leo, 2026-11-07, on
/// three "[message 7f70dca3 from … relayed by the lane-gh broker; its te…" lines) holds none of the
/// message: it reads as nothing, and the line falls back to the message itself or its own words.
/// Only a preview is read so: a whole message that starts like a head keeps its words
/// (withoutRelayLabelOfMessage).
export function withoutRelayHead(preview: string): string {
  return afterHead(preview) ?? (HEAD_START.test(preview) && !preview.includes('"]') ? "" : preview);
}

/// Text that may hold the broker's label whole, or only its head, or a head cut short (a queued
/// message's or a chat's preview, which acpmux cuts to a line): the message alone, else nothing
/// when the cut left none of it.
export function withoutRelayLabel(text: string): string {
  return relayEnvelope(text)?.body ?? withoutRelayHead(text);
}

/// A whole message (a transcript row's, never a preview) without the broker's label: the label
/// whole, or a whole head with no closing line (a record cut after it), is left out; anything else,
/// a message whose own words start "[message 1234 from ", reads as written.
export function withoutRelayLabelOfMessage(text: string): string {
  return relayEnvelope(text)?.body ?? afterHead(text) ?? text;
}
