// Each subagent's unsent prompt (SubagentComposer.tsx), by its draft key (its chat and the
// subagent). The composer unmounts when the person opens the chat ("Subagent of") or another
// subagent, and its page is let go while hidden, reloaded by a web update or quit: a draft outlives
// all of them, as the chat composer's does (composerDraft.ts keeps its text the same way). Review of
// #33280: "Preserve drafts across page release" and "Deliver late failures to an already reopened
// composer".
//
// Every draft is kept in memory and written through to localStorage, which survives the page while
// the app runs (its pages' storage is not kept on disk), and rides in the chat page's wake state
// (`pane.wakeState` subagentDrafts, AgentPaneWakeState.swift), which the host keeps through a quit. One
// the storage refuses (its quota, a big image chip) stays in memory only and holds the page: a
// hidden page is not let go (`pane.wakeState` holdsPageState) and a web update does not reload it
// (webSwap.ts) while it is held. A composer subscribes to its key, so a send that fails after the
// composer it came from is gone reaches the one showing that subagent now.
import { holdWebSwap } from "../../../pages/shared/webSwap";
import { inlineToken, type ComposerAttachment } from "../attachments";

export type Draft = { text: string; attachments: ComposerAttachment[] };

/// A kept draft: what was typed, and when (a draft nobody came back to is dropped after DRAFT_DAYS).
type Kept = Draft & { at: number };

const PREFIX = "cmux.subagentDraft.";
/// A subagent's draft nobody came back to in this long is forgotten when a page next loads.
const DRAFT_DAYS = 14;

const drafts = new Map<string, Draft>();
const unsaved = new Set<string>();
const listeners = new Map<string, Set<(draft: Draft) => void>>();
let loaded = false;

const storage = (): Storage | undefined => {
  try {
    return globalThis.localStorage ?? undefined;
  } catch {
    // Private browsing and test hosts may not provide storage.
    return undefined;
  }
};

/// What a stored value holds, or nothing for a malformed one.
function readKept(value: string | null): Kept | undefined {
  if (!value) return undefined;
  try {
    const kept = JSON.parse(value) as Partial<Kept>;
    if (typeof kept.text !== "string" || !Array.isArray(kept.attachments)) return undefined;
    return {
      text: kept.text,
      attachments: kept.attachments,
      at: typeof kept.at === "number" ? kept.at : 0,
    };
  } catch {
    return undefined;
  }
}

/// Loads the stored drafts once per page, forgetting those older than DRAFT_DAYS.
function load(now: number) {
  if (loaded) return;
  loaded = true;
  const store = storage();
  if (!store) return;
  try {
    const keys: string[] = [];
    for (let index = 0; index < store.length; index += 1) {
      const key = store.key(index);
      if (key?.startsWith(PREFIX)) keys.push(key);
    }
    for (const key of keys) {
      const kept = readKept(store.getItem(key));
      if (!kept || now - kept.at > DRAFT_DAYS * 86_400_000) store.removeItem(key);
      else if (!drafts.has(key.slice(PREFIX.length)))
        drafts.set(key.slice(PREFIX.length), { text: kept.text, attachments: kept.attachments });
    }
  } catch {
    // A storage failure never stops the composer: what is in memory stands.
  }
}

/// The draft kept for `key`, empty when there is none.
export function subagentDraft(key: string, now = Date.now()): Draft {
  load(now);
  return drafts.get(key) ?? { text: "", attachments: [] };
}

/// Keeps `draft` as `key`'s (an empty one is forgotten), in memory and in storage; one the storage
/// refuses holds the page until it is sent, cleared or stored.
export function keepSubagentDraft(key: string, draft: Draft, now = Date.now()) {
  load(now);
  const empty = !draft.text && draft.attachments.length === 0;
  if (empty) drafts.delete(key);
  else drafts.set(key, draft);
  const store = storage();
  try {
    if (empty) store?.removeItem(PREFIX + key);
    else store?.setItem(PREFIX + key, JSON.stringify({ ...draft, at: now } satisfies Kept));
    if (empty || store) unsaved.delete(key);
    else unsaved.add(key);
  } catch {
    // Over the storage's quota: kept in memory, and the page is held so it is not lost.
    unsaved.add(key);
  }
}

/// Puts `draft` in as `key`'s and hands it to the composer showing that subagent, if one is.
export function restoreSubagentDraft(key: string, draft: Draft, now = Date.now()) {
  keepSubagentDraft(key, draft, now);
  for (const listener of listeners.get(key) ?? []) listener(draft);
}

/// Calls `listener` with each draft restored as `key`'s while it is subscribed; returns the
/// unsubscribe.
export function subscribeSubagentDraft(key: string, listener: (draft: Draft) => void): () => void {
  const set = listeners.get(key) ?? new Set();
  set.add(listener);
  listeners.set(key, set);
  return () => {
    set.delete(listener);
    if (set.size === 0) listeners.delete(key);
  };
}

/// Whether a draft is kept only in memory (the storage refused it): the page must not be let go or
/// reloaded while one is.
export function subagentDraftUnsaved(): boolean {
  return unsaved.size > 0;
}

// A web update waits while a draft is kept only in memory: reloading would lose it.
holdWebSwap(() => (unsaved.size > 0 ? "subagent draft" : null));

/// What `draft` says as one message: its pasted chips' text in their places (one not placed goes
/// after), since the relay to the subagent is text only.
export function draftMessage(draft: Draft): string {
  let message = draft.text;
  const loose: string[] = [];
  for (const chip of draft.attachments) {
    const pasted = chip.kind === "pasted" ? (chip.text ?? "") : "";
    const token = inlineToken(chip.id);
    if (message.includes(token)) message = message.split(token).join(pasted);
    else if (pasted) loose.push(pasted);
  }
  return [message, ...loose]
    .filter((part) => part.trim())
    .join("\n\n")
    .trim();
}

/// The most a page's wake state carries of its subagents' drafts: the host keeps a tab's wake state
/// only under its cap (AgentPaneRelaunchWake.maximumTabBytes, 4 MiB), which the chat's own chips
/// share, so drafts past this stay out of it rather than costing the chat its chips.
const WAKE_DRAFT_CHARS = 1_000_000;

/// The drafts a page about to let go (or quit) hands the host, as text (`draftMessage`), newest kept
/// first within WAKE_DRAFT_CHARS; undefined for none.
export function wakeSubagentDrafts(now = Date.now()): Record<string, string> | undefined {
  load(now);
  const out: Record<string, string> = {};
  let total = 0;
  for (const [key, draft] of [...drafts].reverse()) {
    const message = draftMessage(draft);
    if (!message || total + message.length > WAKE_DRAFT_CHARS) continue;
    out[key] = message;
    total += message.length;
  }
  return Object.keys(out).length ? out : undefined;
}

/// Takes back the drafts a woken page's wake state carries (`wakeSubagentDrafts`); a draft this page
/// already keeps for the same subagent (storage outlived the page) is the same or newer and stays.
export function wakeIntoSubagentDrafts(value: unknown, now = Date.now()) {
  if (!value || typeof value !== "object") return;
  load(now);
  for (const [key, text] of Object.entries(value as Record<string, unknown>))
    if (typeof text === "string" && text && !drafts.has(key)) keepSubagentDraft(key, { text, attachments: [] }, now);
}

/// Forgets every draft in memory (the stored ones are read again), for tests.
export function resetSubagentDraftsForTests() {
  drafts.clear();
  unsaved.clear();
  listeners.clear();
  loaded = false;
}
