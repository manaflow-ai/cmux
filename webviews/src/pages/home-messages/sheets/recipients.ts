// New Message's To: field as data (the Swift HomeNewMessageDraft, HomeRecipientToken and
// HomeRecipientSuggestion): the tokens and the text typed after them, the rules that turn text into
// tokens, the suggestions under the field and the conversation the chosen people already have.
// Plain values and pure functions, so the field and its tests share one source of truth.
import type { Strings } from "../../shared/i18n";
import { parseAddress, sameAddress, type ContactAddress } from "./address";

/** Where a person New Message offers comes from. */
export type ContactSource = "team" | "connection" | "agent";

/** A person the user can message: a team member, a connection (a DM both wrote in) or one of the
 * user's Chiefs (`agent`). */
export interface HomeContact {
  id: string;
  name: string;
  source: ContactSource;
}

/** One recipient: someone the user reaches, or an address that gets an invite. */
export type HomeRecipient = { kind: "contact"; contact: HomeContact } | { kind: "address"; address: ContactAddress };

/** One token of the To: field: the text it shows and the recipient it stands for. A token with no
 * recipient draws red and blocks the send until it is removed. */
export interface RecipientToken {
  text: string;
  recipient: HomeRecipient | null;
}

export interface RecipientDraft {
  /** In the order they were added. */
  readonly tokens: readonly RecipientToken[];
  /** The text typed after the last token. */
  readonly query: string;
}

export const EMPTY_DRAFT: RecipientDraft = { tokens: [], query: "" };

export const contactRecipient = (contact: HomeContact): HomeRecipient => ({ kind: "contact", contact });
export const addressRecipient = (address: ContactAddress): HomeRecipient => ({ kind: "address", address });

export function recipientLabel(recipient: HomeRecipient): string {
  return recipient.kind === "contact" ? recipient.contact.name : recipient.address.value;
}

/** The recipient's matching key: an address's text, else the contact's id. */
export function recipientKey(recipient: HomeRecipient): string {
  return recipient.kind === "contact" ? `id:${recipient.contact.id}` : `address:${recipient.address.value}`;
}

export function sameRecipient(a: HomeRecipient, b: HomeRecipient): boolean {
  if (a.kind === "address" && b.kind === "address") return sameAddress(a.address, b.address);
  return recipientKey(a) === recipientKey(b);
}

export const draftRecipients = (draft: RecipientDraft): HomeRecipient[] =>
  draft.tokens.flatMap((token) => (token.recipient ? [token.recipient] : []));

export const hasInvalidTokens = (draft: RecipientDraft) => draft.tokens.some((token) => !token.recipient);

/** Nothing chosen and nothing typed. */
export const isDraftEmpty = (draft: RecipientDraft) => draft.tokens.length === 0 && draft.query.trim() === "";

/** Several people: the first send makes a group. */
export const isGroupDraft = (draft: RecipientDraft) => draftRecipients(draft).length > 1;

const SEPARATORS = /^[\s,;]+|[\s,;]+$/g;
/** The text without the characters that end a token (comma, semicolon, white space) at its ends. */
export const trimSeparators = (text: string) => text.replace(SEPARATORS, "");

/** Case and diacritic insensitive form, as Swift's `[.caseInsensitive, .diacriticInsensitive]`. */
const fold = (text: string) => text.normalize("NFD").replace(/\p{M}/gu, "").toLocaleLowerCase();

const has = (draft: RecipientDraft, recipient: HomeRecipient) =>
  draft.tokens.some((token) => token.recipient && sameRecipient(token.recipient, recipient));

/** Adds a chosen recipient as a token (once) and clears the typed text. */
export function addRecipient(draft: RecipientDraft, recipient: HomeRecipient): RecipientDraft {
  if (has(draft, recipient)) return { ...draft, query: "" };
  return { tokens: [...draft.tokens, { text: recipientLabel(recipient), recipient }], query: "" };
}

/** The recipient `text` names: an email address or phone number, else a contact by exact id or
 * name, else the one contact whose name starts with it. Null when it names nobody. */
export function resolveRecipient(text: string, contacts: readonly HomeContact[]): HomeRecipient | null {
  const trimmed = trimSeparators(text);
  if (!trimmed) return null;
  const address = parseAddress(trimmed);
  if (address) return addressRecipient(address);
  const folded = fold(trimmed);
  const exact = contacts.find((contact) => contact.id === trimmed || fold(contact.name) === folded);
  if (exact) return contactRecipient(exact);
  const starts = contacts.filter((contact) => fold(contact.name).startsWith(folded));
  return starts.length === 1 ? contactRecipient(starts[0]!) : null;
}

/** Return, comma or Tab: the typed text becomes a token, the recipient it names or a red one.
 * `committed` is false when nothing was typed. */
export function commitDraft(
  draft: RecipientDraft,
  contacts: readonly HomeContact[],
): { draft: RecipientDraft; committed: boolean } {
  const text = trimSeparators(draft.query);
  const cleared = { ...draft, query: "" };
  if (!text) return { draft: cleared, committed: false };
  const recipient = resolveRecipient(text, contacts);
  if (!recipient)
    return { draft: { tokens: [...draft.tokens, { text, recipient: null }], query: "" }, committed: true };
  if (has(draft, recipient)) return { draft: cleared, committed: true };
  return {
    draft: { tokens: [...draft.tokens, { text: recipientLabel(recipient), recipient }], query: "" },
    committed: true,
  };
}

/** Backspace with nothing typed removes the last token; null when there was typed text or no token. */
export function deleteBackward(draft: RecipientDraft): RecipientDraft | null {
  if (draft.query !== "" || draft.tokens.length === 0) return null;
  return { ...draft, tokens: draft.tokens.slice(0, -1) };
}

export function removeToken(draft: RecipientDraft, index: number): RecipientDraft {
  if (index < 0 || index >= draft.tokens.length) return draft;
  return { ...draft, tokens: draft.tokens.filter((_, at) => at !== index) };
}

/** The suggestions for the typed text: a typed address first, then people with a word starting
 * with the text, then names that contain it; people already chosen are left out. Empty text
 * suggests nobody (Messages waits for a letter). */
export function suggestRecipients(draft: RecipientDraft, contacts: readonly HomeContact[], limit = 8): HomeRecipient[] {
  const text = trimSeparators(draft.query);
  if (!text) return [];
  const result: HomeRecipient[] = [];
  const address = parseAddress(text);
  if (address && !has(draft, addressRecipient(address))) result.push(addressRecipient(address));
  const folded = fold(text);
  const wordStart = contacts.filter((contact) =>
    fold(contact.name)
      .split(/\s+/)
      .some((word) => word.startsWith(folded)),
  );
  const inside = contacts.filter((contact) => fold(contact.name).includes(folded) && !wordStart.includes(contact));
  for (const contact of [...wordStart, ...inside])
    if (!has(draft, contactRecipient(contact))) result.push(contactRecipient(contact));
  return result.slice(0, limit);
}

/** The Chiefs listed before anything is typed: the user's Chiefs not chosen yet, at most `limit`. */
export function chiefShortcuts(draft: RecipientDraft, contacts: readonly HomeContact[], limit = 6): HomeContact[] {
  return contacts
    .filter((contact) => contact.source === "agent" && !has(draft, contactRecipient(contact)))
    .slice(0, limit);
}

/** The people listed before anything is typed: the Chiefs, then every team member not chosen yet. */
export function idleSuggestions(
  draft: RecipientDraft,
  contacts: readonly HomeContact[],
  chiefLimit = 6,
): HomeContact[] {
  const team = contacts.filter((contact) => contact.source === "team" && !has(draft, contactRecipient(contact)));
  return [...chiefShortcuts(draft, contacts, chiefLimit), ...team];
}

/** A conversation row as `existingConversation` reads it (home-channels' HomeConversation fits). */
export interface ExistingConversationRow {
  id: string;
  kind: "chief" | "direct" | "group";
  participants: readonly { id: string; /** The address a not-yet-joined person was invited by. */ invited?: string }[];
}

/** The conversation that already has exactly the chosen people (one person: their DM or the
 * Chief's; several: a group with exactly them), first as the list orders them. Null while a token
 * is red or nobody is chosen. An address matches a person invited by that address. */
export function existingConversation(
  draft: RecipientDraft,
  rows: readonly ExistingConversationRow[],
  me: string | undefined,
): string | null {
  const recipients = draftRecipients(draft);
  if (recipients.length === 0 || hasInvalidTokens(draft)) return null;
  const wanted = new Set(recipients.map(recipientKey));
  const key = (participant: ExistingConversationRow["participants"][number]) => {
    const address = participant.invited ? parseAddress(participant.invited) : null;
    return address ? `address:${address.value}` : `id:${participant.id}`;
  };
  const match = rows.find((row) => {
    if (recipients.length === 1 ? row.kind === "group" : row.kind !== "group") return false;
    const others = row.participants.filter((participant) => participant.id !== me);
    if (others.length !== wanted.size) return false;
    const keys = new Set(others.map(key));
    return keys.size === wanted.size && [...wanted].every((entry) => keys.has(entry));
  });
  return match?.id ?? null;
}

/** Why the first send cannot go yet (a red token first, then nobody chosen), or null. */
export function sendBlocker(draft: RecipientDraft, strings: Strings): string | null {
  const invalid = draft.tokens.find((token) => !token.recipient);
  if (invalid) return strings.format("home.compose.unknownRecipient", invalid.text);
  return draftRecipients(draft).length === 0 ? strings.t("home.compose.needsRecipient") : null;
}

// ---------- The list under the field ----------

/** One row of the list under To:: a section header, a recipient, or an action row that runs
 * instead of adding a token. */
export type SuggestionRow =
  | { kind: "header"; title: string }
  | { kind: "recipient"; recipient: HomeRecipient }
  /** Makes another Chief (`home.newChief`), after the Chiefs. */
  | { kind: "newChief" }
  /** Invites someone (`home.invite`), when the Team section has nobody. */
  | { kind: "invite" }
  /** Invites the typed address to the active team (`home.inviteToTeam`), after the address row. */
  | { kind: "inviteToTeam"; address: ContactAddress; team: string };

/** False for a header: Up, Down, a click and Return skip it. */
export const isSelectable = (row: SuggestionRow) => row.kind !== "header";

/** The list before anything is typed: the Chiefs under "Chiefs" with New Chief after them, then
 * everyone else under "Team" (an Invite row when the team has nobody). */
export function idleRows(
  offered: readonly HomeContact[],
  options: { newChief: boolean; invite: boolean },
  strings: Strings,
): SuggestionRow[] {
  const chiefs = offered.filter((contact) => contact.source === "agent");
  const team = offered.filter((contact) => contact.source !== "agent");
  const rows: SuggestionRow[] = [];
  if (chiefs.length > 0 || options.newChief) {
    rows.push({ kind: "header", title: strings.t("home.list.section.chiefs") });
    for (const chief of chiefs) rows.push({ kind: "recipient", recipient: contactRecipient(chief) });
    if (options.newChief) rows.push({ kind: "newChief" });
  }
  if (team.length > 0 || options.invite) {
    rows.push({ kind: "header", title: strings.t("home.compose.section.team") });
    if (team.length === 0) rows.push({ kind: "invite" });
    else for (const person of team) rows.push({ kind: "recipient", recipient: contactRecipient(person) });
  }
  return rows;
}

/** The list while something is typed: the matches, and after a typed email address an "Invite …
 * to <team>" row when there is an active team. */
export function typedRows(
  draft: RecipientDraft,
  contacts: readonly HomeContact[],
  inviteTeam: string | null,
): SuggestionRow[] {
  const matches = suggestRecipients(draft, contacts);
  const rows: SuggestionRow[] = matches.map((recipient) => ({ kind: "recipient", recipient }));
  const email = matches.find((match) => match.kind === "address" && match.address.kind === "email");
  if (inviteTeam !== null && email?.kind === "address") {
    const at = rows.findIndex((row) => row.kind === "recipient" && row.recipient === email);
    rows.splice(at < 0 ? rows.length : at + 1, 0, { kind: "inviteToTeam", address: email.address, team: inviteTeam });
  }
  return rows;
}

/** How a row draws one recipient beyond its name: where a Chief runs ("Main · Cloud"), and when it
 * was last active (shown only to tell alike rows apart). */
export interface RecipientLook {
  tag?: string;
  activity?: string;
}

/** What a recipient is, as the line under its name. */
export function recipientDetail(recipient: HomeRecipient, strings: Strings): string {
  if (recipient.kind === "address")
    return strings.t(recipient.address.kind === "email" ? "home.compose.address.email" : "home.compose.address.phone");
  const source = recipient.contact.source;
  return strings.t(
    source === "team"
      ? "home.compose.source.team"
      : source === "agent"
        ? "home.compose.source.agent"
        : "home.compose.source.connection",
  );
}

/** Each recipient row's line under its name, by row index. A row that, name and line, reads the
 * same as another gets when it was last active; still alike, a number ("2"). */
export function suggestionLines(
  rows: readonly SuggestionRow[],
  look: (recipient: HomeRecipient) => RecipientLook,
  strings: Strings,
): Map<number, string> {
  const lines = new Map<number, string>();
  const looks = new Map<number, RecipientLook>();
  rows.forEach((row, index) => {
    if (row.kind !== "recipient") return;
    const shown = look(row.recipient);
    looks.set(index, shown);
    lines.set(index, [recipientDetail(row.recipient, strings), shown.tag].filter(Boolean).join(" · "));
  });
  const collisions = () => {
    const groups = new Map<string, number[]>();
    for (const index of [...lines.keys()].sort((a, b) => a - b)) {
      const row = rows[index]!;
      if (row.kind !== "recipient") continue;
      const key = `${recipientLabel(row.recipient)}\u0000${lines.get(index)}`;
      groups.set(key, [...(groups.get(key) ?? []), index]);
    }
    return [...groups.values()].filter((group) => group.length > 1);
  };
  for (const group of collisions())
    for (const index of group) {
      const activity = looks.get(index)?.activity;
      if (activity) lines.set(index, `${lines.get(index)} · ${activity}`);
    }
  for (const group of collisions())
    group.forEach((index, number) => {
      if (number > 0) lines.set(index, `${lines.get(index)} · ${number + 1}`);
    });
  return lines;
}
