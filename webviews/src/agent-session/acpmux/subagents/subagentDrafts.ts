// Each subagent's unsent prompt (SubagentComposer.tsx), by its draft key (its chat and the
// subagent). The composer unmounts when the person opens the chat ("Subagent of") or another
// subagent, and its page is let go while hidden, reloaded by a web update or quit: a draft outlives
// all of them, as the chat composer's does (composerDraft.ts keeps its text the same way). Review of
// #33280: "Preserve drafts across page release" and "Deliver late failures to an already reopened
// composer".
//
// Every draft is kept in memory and written through to localStorage, which survives the page while
// the app runs (its pages' storage is not kept on disk), and rides in the wake state of the page it
// was typed in (`pane.wakeState` subagentDrafts, AgentPaneWakeState.swift), with when it was kept:
// the host keeps it through a quit, its text in a file of its own (AgentPaneRelaunchWake.swift), so a
// draft of any size comes back, and of two pages' copies the newer one wins. One
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
/// When each draft in `drafts` was last kept, which decides between two copies of it.
const keptAt = new Map<string, number>();
/// The drafts this page kept (typed here, or woken into it): only these ride in its wake state, so
/// no tab carries other tabs' drafts.
const keptHere = new Set<string>();
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
      else if (!drafts.has(key.slice(PREFIX.length))) {
        drafts.set(key.slice(PREFIX.length), { text: kept.text, attachments: kept.attachments });
        keptAt.set(key.slice(PREFIX.length), kept.at);
      }
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
  // An emptied draft stays this page's to hand on: a newer empty copy clears an older one.
  keptHere.add(key);
  if (empty) {
    drafts.delete(key);
  } else {
    drafts.set(key, draft);
  }
  keptAt.set(key, now);
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

/// The drafts kept only in memory (the storage refused them), each with its chat, forgotten here: a
/// closing page has nowhere else to keep them, so it hands each to its chat's own draft, which
/// outlives the page (App.tsx `pane.wakeState`, review of #33280).
export function takeUnsavedSubagentDrafts(): { chat: string; draft: Draft }[] {
  const taken: { chat: string; draft: Draft }[] = [];
  for (const key of unsaved) {
    const draft = drafts.get(key);
    const split = key.indexOf("\u0000");
    if (draft && split > 0) taken.push({ chat: key.slice(0, split), draft });
    drafts.delete(key);
    keptAt.delete(key);
    keptHere.delete(key);
  }
  unsaved.clear();
  return taken;
}

// A web update waits while a draft is kept only in memory: reloading would lose it.
holdWebSwap(() => (unsaved.size > 0 ? "subagents.draft-unsaved" : null));

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

/// A draft as a page's wake state carries it: its text (`draftMessage`) and when it was kept. An
/// empty text is a cleared draft, which wins over an older copy too.
export type WokenDraft = { text: string; at: number };

/// The drafts a page about to let go (or quit) hands the host: those it kept, and those of `chat`, the
/// chat it shows (a page a web update reloaded keeps them in storage only); undefined for none. Each
/// goes whatever its size: the host keeps its text in a file of its own.
export function wakeSubagentDrafts(chat?: string, now = Date.now()): Record<string, WokenDraft> | undefined {
  load(now);
  const out: Record<string, WokenDraft> = {};
  const keys = new Set(keptHere);
  if (chat !== undefined) for (const key of drafts.keys()) if (key.startsWith(`${chat}\u0000`)) keys.add(key);
  for (const key of keys) {
    const draft = drafts.get(key);
    const at = keptAt.get(key) ?? now;
    // A cleared draft is handed on only while an older copy could still be around.
    if (!draft && now - at > DRAFT_DAYS * 86_400_000) continue;
    out[key] = { text: draft ? draftMessage(draft) : "", at };
  }
  return Object.keys(out).length ? out : undefined;
}

/// Takes back the drafts a woken page's wake state carries (`wakeSubagentDrafts`): each one newer
/// than the copy this page has (storage outlived the page, or another page woke first) replaces it.
export function wakeIntoSubagentDrafts(value: unknown, now = Date.now()) {
  if (!value || typeof value !== "object") return;
  load(now);
  for (const [key, woken] of Object.entries(value as Record<string, unknown>)) {
    const { text, at } = (woken ?? {}) as Partial<WokenDraft>;
    if (typeof text !== "string" || typeof at !== "number") continue;
    if (keptAt.has(key) && (keptAt.get(key) ?? 0) >= at) continue;
    // Kept, not restored: the page has just started, before a composer reads it, and a restore
    // reads to a shown composer as a failed send.
    keepSubagentDraft(key, { text, attachments: [] }, at);
  }
}

/// Forgets every draft in memory (the stored ones are read again), for tests.
export function resetSubagentDraftsForTests() {
  drafts.clear();
  keptAt.clear();
  keptHere.clear();
  unsaved.clear();
  listeners.clear();
  loaded = false;
}
