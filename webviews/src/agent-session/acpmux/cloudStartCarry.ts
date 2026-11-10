// What was typed in the composer while a Cloud start was out, carried to the chat that start opens
// (Leo, 2026-11-09: "I can't click into the composer at all to, like potentially type other stuff
// while it's doing that initial load situation"). The composer takes typing during the start, but on
// success the host opens the chat in a new tab on the machine and closes this one, which never
// started a chat (CloudStartChat.swift), so its draft would go with it. Every agent pane is the same
// bundled page, so they share `localStorage`: this page keeps what was typed past the sent prompt
// there, and the Cloud chat's page, starting with that prompt as its seed, puts it in its composer
// once. Only text: an attachment's file is this Mac's and its token names a chip only this page has.
// A failed start keeps the draft in this page's composer, so the carry goes.

export type CloudStartCarry = { task: string; text: string; at: number };

/// Where the carry is kept: the page's `localStorage` (shared by every agent pane).
export type CarryStore = {
  getItem(name: string): string | null;
  setItem(name: string, value: string): void;
  removeItem(name: string): void;
};

const KEY = "cmux.cloudStartCarry";
/// A carry older than this belongs to no start the page could still be opening.
export const CARRY_TTL_MS = 30 * 60_000;

const store = (): CarryStore | undefined => {
  try {
    return globalThis.localStorage ?? undefined;
  } catch {
    return undefined;
  }
};

/// An attachment's token in the draft (attachments.ts inlineToken): its chip stays on this page.
const TOKEN = /￼[^￼]*￼/g;

/// What `draft` holds past the sent `task`: the text after it when the draft still starts with it,
/// else the whole draft (the prompt itself was edited); "" when nothing was added.
export function carriedText(task: string, draft: string): string {
  const text = draft.replace(TOKEN, "").trim();
  const sent = task.replace(TOKEN, "").trim();
  if (!text || text === sent) return "";
  return sent && text.startsWith(sent) ? text.slice(sent.length).trim() : text;
}

/// The composer's draft changed while the start of `task` is out: keep what it adds.
export function holdCloudCarry(task: string, draft: string, now = Date.now(), at: CarryStore | undefined = store()) {
  if (!at) return;
  const text = carriedText(task, draft);
  try {
    if (text) at.setItem(KEY, JSON.stringify({ task, text, at: now } satisfies CloudStartCarry));
    else at.removeItem(KEY);
  } catch {
    // A full or refused store keeps nothing: the draft stays in this page until it closes.
  }
}

/// The start ended here (failed, cancelled, run on this Mac): the draft stays in this composer.
export function dropCloudCarry(at: CarryStore | undefined = store()) {
  try {
    at?.removeItem(KEY);
  } catch {
    // Nothing kept to drop.
  }
}

/// A chat whose seeded first prompt is `prompt` opened: the text typed while its start was out, once.
export function takeCloudCarry(
  prompt: string,
  now = Date.now(),
  at: CarryStore | undefined = store(),
): string | undefined {
  if (!at) return undefined;
  let carry: Partial<CloudStartCarry> | undefined;
  try {
    const raw = at.getItem(KEY);
    carry = raw ? (JSON.parse(raw) as Partial<CloudStartCarry>) : undefined;
  } catch {
    carry = undefined;
  }
  if (!carry || typeof carry.text !== "string" || typeof carry.task !== "string" || typeof carry.at !== "number")
    return undefined;
  if (now - carry.at > CARRY_TTL_MS) {
    dropCloudCarry(at);
    return undefined;
  }
  if (carry.task.replace(TOKEN, "").trim() !== prompt.replace(TOKEN, "").trim()) return undefined;
  dropCloudCarry(at);
  return carry.text || undefined;
}
