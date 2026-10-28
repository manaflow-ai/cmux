// Several people in one chat (hq plans/cmux-next/chat-multiplayer/DESIGN.md). Leo, 2026-10-26: "we
// can still do the regular chat multiplayer". The pane reads who sent a prompt, who answered an
// ask, and who is here and typing from acpmux's records through these readers only, so the rows
// and the header render from plain fields (and from gallery fixtures) before the sync lands.
//
// The author is stamped by the host's daemon, never named by a client: a prompt's
// `_meta.provenance` of kind `person_message` `{from, fromName}`, and a decision's
// `answeredBy {id, name}` (a paired device's is `{device, feedItem}`, a question's ancestor
// `{session, name}`). Presence and typing are ephemeral (`_acpmux/presence`), never in the log.

/// One person in a chat. `avatar` is a picture's data URL; none draws their initials.
export type Participant = { id: string; name: string; avatar?: string };

/// Who else has the chat open, and who of them is typing; this reader is never in either list.
export type ChatPresence = { viewing: Participant[]; typing: Participant[] };

/// Longest name the pane draws, as acpmux bounds a surface's name.
const MAX_NAME = 64;
/// Longest id the pane keeps; a longer one is not a person acpmux would stamp.
const MAX_ID = 256;

/// A character a name may not hold (acpmux hub/composers.rs `hidden`): a control, or an invisible
/// format character (`\p{Cf}`: a bidi override, a zero-width one, a Unicode tag) that could make a
/// name read as another, and the Mongolian vowel separator, which is no longer a format character.
const HIDDEN = /[\p{Cc}\p{Cf}\u180E]/gu;

/// A name as the pane draws it: hidden characters removed, one line, at most 64 characters.
export function displayName(value: unknown): string | undefined {
  if (typeof value !== "string") return undefined;
  const shown = Array.from(value.replace(HIDDEN, "").replace(/\s+/g, " ").trim()).slice(0, MAX_NAME).join("");
  return shown || undefined;
}

/// An id kept whole, so two ids that share a prefix stay two people.
const identity = (value: unknown): string | undefined =>
  typeof value === "string" && value.trim() && value.length <= MAX_ID ? value.trim() : undefined;

/// Only an inline picture: a link would load from wherever a record points.
const picture = (value: unknown): string | undefined =>
  typeof value === "string" && /^data:image\/(png|jpeg|gif|webp);base64,/.test(value) ? value : undefined;

export function participant(id: unknown, name: unknown, avatar?: unknown): Participant | undefined {
  const key = identity(id);
  if (!key) return undefined;
  const shown = picture(avatar);
  return { id: key, name: displayName(name) ?? displayName(key) ?? "?", ...(shown && { avatar: shown }) };
}

/// The person who sent a `user_message` or `queued` record, or undefined for the chat owner's own.
export function promptAuthor(msg: { _meta?: { provenance?: unknown } } | undefined): Participant | undefined {
  const provenance = msg?._meta?.provenance as Record<string, unknown> | undefined;
  if (provenance?.kind !== "person_message") return undefined;
  return participant(provenance.from, provenance.fromName, provenance.fromAvatar);
}

/// The person who answered an ask (`permission_decision.answeredBy {id, name}`), or undefined when
/// acpmux names a device, a session or nobody (null: the owner answered).
export function answeredBy(value: unknown): Participant | undefined {
  if (!value || typeof value !== "object") return undefined;
  const by = value as Record<string, unknown>;
  if (typeof by.session === "string" || typeof by.device === "string") return undefined;
  return participant(by.id, by.name, by.avatar);
}

/// The chat's presence from `_acpmux/presence {participants: [{id, name, devices, viewing, typing}]}`.
/// The reader's own entry is left out (`me`, the author id this pane sends as; acpmux names a caller
/// with no author `owner`): nobody needs to see they are here.
export function chatPresence(value: unknown, me = "owner"): ChatPresence {
  const list = (value as { participants?: unknown } | undefined)?.participants;
  const viewing: Participant[] = [];
  const typing: Participant[] = [];
  if (!Array.isArray(list)) return { viewing, typing };
  const seen = new Set<string>();
  for (const entry of list) {
    if (!entry || typeof entry !== "object") continue;
    const raw = entry as Record<string, unknown>;
    const person = participant(raw.id, raw.name, raw.avatar);
    if (!person || person.id === me || seen.has(person.id)) continue;
    seen.add(person.id);
    if (raw.viewing === true || raw.typing === true) viewing.push(person);
    if (raw.typing === true) typing.push(person);
  }
  return { viewing, typing };
}

/// Up to two initials of a name, by grapheme, so an accent or an emoji stays whole.
export function initials(name: string, count = 2): string {
  const words = name.trim().split(/\s+/).filter(Boolean);
  const first = (word: string) => Array.from(new Intl.Segmenter().segment(word), (part) => part.segment);
  const letters = words.length > 1 ? [first(words[0]!)[0], first(words[1]!)[0]] : first(words[0] ?? "?").slice(0, 2);
  // Whole graphemes only: a UTF-16 slice of the joined string would split a surrogate pair.
  return letters.slice(0, count).join("").toUpperCase();
}
