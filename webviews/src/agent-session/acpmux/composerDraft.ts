import { useSyncExternalStore } from "react";
import { holdWebSwap } from "../../pages/shared/webSwap";

/**
 * A new chat's inherited draft (a terminal selection, a page's URL), or undefined when
 * the handshake carries none. It is shown in the composer, never sent by itself.
 */
export function composerDraft(draft: unknown): string | undefined {
  return typeof draft === "string" && draft.trim() ? draft : undefined;
}

function daemonDraft(result: unknown): string | undefined {
  if (result && typeof result === "object" && "draft" in result) {
    return composerDraft((result as { draft?: unknown }).draft);
  }
  return composerDraft(result);
}

/** The composer text once a draft arrives: the draft, unless the user already typed something. */
export function seededText(current: string, draft: string | undefined): string {
  return draft && !current ? draft : current;
}

/**
 * The prompt once a saved draft (acpmux's, the tab's kept unsent text, the page's remount cache)
 * meets text the composer already holds, typed before the chat finished loading. Nothing is lost
 * and nothing is doubled: an empty side gives way to the other, text that already holds the saved
 * draft stays as it is, and two different texts are both kept, the saved draft first and the typed
 * text after it. That is the order `ComposerHandle.restore` uses (what comes back goes first): the
 * caret stays at the end of what the person is typing, so their next key lands where they expect.
 */
export function mergedDraft(typed: string, saved: string | undefined): string {
  if (!saved?.trim()) return typed;
  if (!typed.trim()) return saved;
  if (typed.includes(saved)) return typed;
  // Already merged once (a second load, the host's own merge): the same text again.
  if (saved.endsWith(`\n\n${typed}`)) return saved;
  return `${saved}\n\n${typed}`;
}

/**
 * What the composer does when acpmux's draft read answers (`readDurableDraftState`). One rule:
 * once the person touched this chat's prompt (`local`: an edit or a send, in this mount or an
 * earlier one, or a write still queued or unanswered), what the page holds is the draft, and
 * acpmux's is never merged into it. The one exception is text typed before this page ever read the
 * chat's draft (`read` false: the chat still loading after a launch or reload): that text was not
 * built on acpmux's, so both are kept (`mergedDraft`), unless the person already sent it.
 * Untouched, with nothing on its way, acpmux's draft fills the prompt; on the page's first read
 * whatever the prompt holds (the remount cache, an inherited draft) is kept beside it.
 * `text` is the prompt to show, `shown` whether it differs from the editor, and `write` whether it
 * goes to acpmux.
 */
export function hydratedDraft(input: {
  current: string;
  restored: string | undefined;
  /** This page read the chat's acpmux draft before (in this mount or an earlier one). */
  read: boolean;
  /** The person edited the prompt since the last settled read. */
  edited: boolean;
  /** The person sent from the prompt since the last settled read. */
  sent: boolean;
  /** A write of this page's is queued or unanswered. */
  pendingWrite: boolean;
}): { text: string; shown: boolean; write: boolean } {
  const { current, restored, read, edited, sent, pendingWrite } = input;
  // The prompt as it is; it goes to acpmux when acpmux holds something else and nothing is on its way.
  const keep = () => ({ text: current, shown: false, write: !pendingWrite && current !== (restored ?? "") });
  const merge = () => {
    const text = mergedDraft(current, restored);
    return { text, shown: text !== current, write: text !== (restored ?? "") && Boolean(text.trim()) };
  };
  if (edited || sent || pendingWrite) {
    if (sent || pendingWrite || read || !restored) return keep();
    return merge();
  }
  if (read) {
    const text = restored ?? "";
    return { text, shown: text !== current, write: false };
  }
  return restored ? merge() : keep();
}

const PERSISTED_DRAFT_PREFIX = "cmux.acpmux.composer-draft.";

type DraftAction = (params: Record<string, unknown>) => Promise<unknown>;

const DRAFT_ACTIONS_CHANGED = "cmux.acpmux.actions-changed";
const draftActionSubscribers = new Set<() => void>();
let draftActionsVersion = 0;
let draftWriteSequence = 0;
let flushingDraftWrites = false;
// The drain running now (while `flushingDraftWrites`), so a quit can wait for it (settlePendingDraftWrites).
let draftDrain: Promise<void> | undefined;
// The newest text this page handed to acpmux, by session: a quit compares the editor's value with
// it, so text acpmux already holds is not written again over another pane's newer edit. An entry
// goes when its composer leaves the chat or closes (forgetQueuedDraft), or the draft is cleared, so
// the map holds at most one entry per open composer.
const lastQueuedDraft = new Map<string, string>();
const pendingDraftWrites = new Map<string, { sessionId: string; text: string; sequence: number }>();
// The write sent to acpmux and not yet answered, by session: until acpmux says it holds it, its text
// is newer than any draft a read returns, so a remount's read never merges the older draft into it.
// An entry goes when its answer comes (or it fails and goes back in `pendingDraftWrites`).
const sentDraftWrites = new Map<string, number>();
// WEB-SWAP: a web update's reload waits until acpmux holds every draft (pages/shared/webSwap.ts):
// a reload before a clear lands would bring the old draft back from acpmux. A write that failed or
// timed out stays queued, and each ask retries it, so the hold ends once acpmux answers again. A
// write that timed out and may still land holds it too, but only for `draftWriteLimits.lateHoldMs`
// after it timed out: a request that never answers cannot hold a web update forever. (A reload
// then starts a new connection, which takes the queue from the page's own copy.)
holdWebSwap(() => {
  if (pendingDraftWrites.size && !flushingDraftWrites) flushPendingDraftWrites();
  if (unansweredWrite && Date.now() - unansweredWrite.since >= draftWriteLimits.lateHoldMs) return null;
  return pendingDraftWrites.size || flushingDraftWrites || unansweredWrite ? "composer.draft-unsaved" : null;
});

// l10n-allow: a sentinel matched by identity (writeTimedOut); never shown.
const WRITE_TIMED_OUT = new Error("chat.writeDraft timed out");

/** How long one draft write may go unanswered before it counts as failed, and how long after that
 * a web swap still waits in case it lands late (tests change them). */
export const draftWriteLimits = { timeoutMs: 5_000, lateHoldMs: 30_000 };

// A write that timed out may still land later. Nothing newer goes through the same connection
// until it answers, so it can never land over a newer draft or a clear, and nothing is replayed.
// It is dropped when the action is replaced (a reconnect: its request went with the old
// connection). Writes on a connection that never answers wait, as they always did; only the
// web-swap hold above is bounded.
let unansweredWrite: { action: DraftAction; since: number } | undefined;

function writeTimedOut(action: DraftAction, sessionId: string, sequence: number, sent: Promise<unknown>): void {
  const late = { action, since: Date.now() };
  unansweredWrite = late;
  const answered = () => {
    if (unansweredWrite !== late) return;
    unansweredWrite = undefined;
    flushPendingDraftWrites();
  };
  void Promise.resolve(sent).then(() => {
    // It landed: its own retry, still queued, would only land over a later edit.
    if (pendingDraftWrites.get(sessionId)?.sequence === sequence) pendingDraftWrites.delete(sessionId);
    answered();
  }, answered);
  // Its retry is queued (`pendingDraftWrites`), which keeps the text authoritative meanwhile.
  if (sentDraftWrites.get(sessionId) === sequence) sentDraftWrites.delete(sessionId);
}

/** `write`, or a rejection once it has gone unanswered for `draftWriteLimits.timeoutMs`. */
function answeredInTime(write: Promise<unknown>): Promise<unknown> {
  let timer: ReturnType<typeof setTimeout> | undefined;
  const late = new Promise<never>((_, reject) => {
    timer = setTimeout(() => reject(WRITE_TIMED_OUT), draftWriteLimits.timeoutMs);
  });
  return Promise.race([write, late]).finally(() => clearTimeout(timer));
}

function pageDraftAction(name: "chat.readDraft" | "chat.writeDraft"): DraftAction | undefined {
  const page = (
    globalThis as typeof globalThis & {
      window?: { cmuxAcpmuxActions?: Record<string, DraftAction> };
    }
  ).window;
  return page?.cmuxAcpmuxActions?.[name];
}

function persistedDraftKey(sessionId: string | undefined): string | undefined {
  if (!sessionId?.trim()) return undefined;
  return `${PERSISTED_DRAFT_PREFIX}${encodeURIComponent(sessionId)}`;
}

function draftActionsChanged(): void {
  draftActionsVersion += 1;
  for (const subscriber of draftActionSubscribers) subscriber();
}

function draftActionsChangedAndFlush(): void {
  draftActionsChanged();
}

/** Notifies the composer that the native action map was installed or replaced. */
export function notifyDraftActionsChanged(): void {
  draftActionsChangedAndFlush();
}

/** Re-renders a composer when a reconnect installs the native action map. */
export function useDraftActionsVersion(): number {
  return useSyncExternalStore(
    (subscriber) => {
      draftActionSubscribers.add(subscriber);
      const page = (globalThis as typeof globalThis & { window?: Window }).window;
      page?.addEventListener(DRAFT_ACTIONS_CHANGED, draftActionsChangedAndFlush);
      return () => {
        draftActionSubscribers.delete(subscriber);
        page?.removeEventListener(DRAFT_ACTIONS_CHANGED, draftActionsChangedAndFlush);
      };
    },
    () => draftActionsVersion,
    () => 0,
  );
}

async function flushDraftWrites(): Promise<void> {
  if (flushingDraftWrites || !pageDraftAction("chat.writeDraft")) return;
  flushingDraftWrites = true;
  try {
    while (pendingDraftWrites.size) {
      const action = pageDraftAction("chat.writeDraft");
      if (!action) break;
      if (unansweredWrite?.action !== action) unansweredWrite = undefined;
      // A write that timed out may still land: anything newer waits for its answer (writeTimedOut).
      if (unansweredWrite) break;
      const next = pendingDraftWrites.entries().next().value as
        | [string, { sessionId: string; text: string; sequence: number }]
        | undefined;
      if (!next) break;
      const [sessionId, write] = next;
      pendingDraftWrites.delete(sessionId);
      sentDraftWrites.set(sessionId, write.sequence);
      let sent: Promise<unknown> | undefined;
      try {
        sent = action({ sessionId: write.sessionId, text: write.text });
        // A write that never answers would keep this drain, and the web-swap hold, forever.
        await answeredInTime(sent);
        if (sentDraftWrites.get(sessionId) === write.sequence) sentDraftWrites.delete(sessionId);
      } catch (error) {
        if (sentDraftWrites.get(sessionId) === write.sequence) sentDraftWrites.delete(sessionId);
        if (error === WRITE_TIMED_OUT && sent) writeTimedOut(action, sessionId, write.sequence, sent);
        // A disconnect can invalidate the action while it is in flight, or it never answers. Keep
        // the newest value for the next try, while preserving a later keystroke already in the queue.
        const current = pendingDraftWrites.get(sessionId);
        if (!current || current.sequence === write.sequence) pendingDraftWrites.set(sessionId, write);
        break;
      }
    }
  } finally {
    flushingDraftWrites = false;
  }
}

// A running drain picks up every write queued before its loop ends: the loop re-reads the queue after
// each answer, and `flushingDraftWrites` clears in the same turn the loop sees it empty. So a write
// either joins the running drain or starts a new one; none waits for a drain that already finished.
function drainDraftWrites(): Promise<void> {
  if (!flushingDraftWrites) draftDrain = flushDraftWrites();
  return draftDrain ?? Promise.resolve();
}

/** Flushes writes after the composer has completed its durable restore. */
export function flushPendingDraftWrites(): void {
  void drainDraftWrites();
}

/**
 * Resolves once acpmux holds every draft typed so far, the last keystroke included: a page about to
 * let go (`pane.wakeState`, asked on every quit, an update's relaunch too) waits for it so the
 * process cannot end with a write still on its way. A write that fails keeps its text queued for the
 * next connection and resolves this at once.
 */
export function settlePendingDraftWrites(): Promise<void> {
  return pendingDraftWrites.size || flushingDraftWrites ? drainDraftWrites() : Promise.resolve();
}

/** The newest text this page queued for `sessionId`'s acpmux draft, or undefined when none is kept. */
export function lastQueuedDraftText(sessionId: string): string | undefined {
  return lastQueuedDraft.get(sessionId);
}

/** A composer left `sessionId` (another chat, or the pane closed): its queued text is not compared again. */
export function forgetQueuedDraft(sessionId: string | undefined): void {
  if (sessionId) lastQueuedDraft.delete(sessionId);
}

/** Returns whether a write this page made owns the session's newest value: one queued, or one sent
 * that acpmux has not answered yet. Either is newer than the draft a read returns meanwhile. */
export function hasPendingDraftWrite(sessionId: string | undefined): boolean {
  return Boolean(sessionId && (pendingDraftWrites.has(sessionId) || sentDraftWrites.has(sessionId)));
}

/// Reads the last unsent prompt from the page's synchronous remount cache.
export function readPersistedDraft(sessionId: string | undefined): string | undefined {
  const key = persistedDraftKey(sessionId);
  if (!key) return undefined;
  try {
    return composerDraft(globalThis.localStorage?.getItem(key));
  } catch {
    // Private browsing and test hosts may not provide writable storage.
    return undefined;
  }
}

/// Stores text typed before the chat's acpmux draft was read in the remount cache only: a remount
/// (the composer swapped out while the chat loads or reconnects) brings it back, and the read
/// merges it with acpmux's draft before anything goes to acpmux.
export function cachePersistedDraft(sessionId: string | undefined, text: string): void {
  const key = persistedDraftKey(sessionId);
  if (!key) return;
  try {
    if (text.trim()) globalThis.localStorage?.setItem(key, text);
    else globalThis.localStorage?.removeItem(key);
  } catch {
    // A storage failure must never interrupt typing or sending.
  }
}

/// Stores or clears an unsent prompt in the remount cache and daemon session state.
export function writePersistedDraft(sessionId: string | undefined, text: string): void {
  if (!sessionId?.trim()) return;
  cachePersistedDraft(sessionId, text);
  // Keep only the newest value per session. This preserves clear-after-type ordering when a
  // connection is down, without dropping the final clear or sending stale keystrokes on repair.
  pendingDraftWrites.set(sessionId, { sessionId, text, sequence: ++draftWriteSequence });
  // A cleared draft is nothing to compare with: its entry goes, so the map holds only live drafts.
  if (text) lastQueuedDraft.set(sessionId, text);
  else lastQueuedDraft.delete(sessionId);
  flushPendingDraftWrites();
}

/// Reads the daemon draft; a missing page action is expected in browser-only and test hosts.
export async function readDurableDraft(sessionId: string | undefined): Promise<string | undefined> {
  return (await readDurableDraftState(sessionId))?.draft;
}

// Per chat, for the page's life (unmounts and remounts included, so a composer that comes back
// keeps it): whether this page read the chat's acpmux draft, and whether the person edited or sent
// from its prompt since the last settled read (`hydratedDraft`). One entry per chat the page opened.
const chatDrafts = new Map<string, { read: boolean; edited: boolean; sent: boolean }>();

function chatDraft(sessionId: string) {
  let entry = chatDrafts.get(sessionId);
  if (!entry) chatDrafts.set(sessionId, (entry = { read: false, edited: false, sent: false }));
  return entry;
}

/** What `hydratedDraft` needs to know of `sessionId` besides the texts. */
export function draftHistory(sessionId: string | undefined): {
  read: boolean;
  edited: boolean;
  sent: boolean;
  pendingWrite: boolean;
} {
  const entry = sessionId ? chatDrafts.get(sessionId) : undefined;
  return {
    read: entry?.read ?? false,
    edited: entry?.edited ?? false,
    sent: entry?.sent ?? false,
    pendingWrite: hasPendingDraftWrite(sessionId),
  };
}

/** Whether this page has read `sessionId`'s acpmux draft before. */
export function draftWasRead(sessionId: string | undefined): boolean {
  return Boolean(sessionId && chatDrafts.get(sessionId)?.read);
}

/** A read of `sessionId`'s draft answered and was applied. With nothing of the page's still on its
 * way to acpmux, the prompt and acpmux agree from here: earlier edits and sends are settled. */
export function markDraftRead(sessionId: string | undefined): void {
  if (!sessionId?.trim()) return;
  const entry = chatDraft(sessionId);
  entry.read = true;
  if (!hasPendingDraftWrite(sessionId)) {
    entry.edited = false;
    entry.sent = false;
  }
}

/** The person edited `sessionId`'s prompt (a clear included). */
export function noteDraftEdited(sessionId: string | undefined): void {
  if (sessionId?.trim()) chatDraft(sessionId).edited = true;
}

/** The person sent from `sessionId`'s prompt: the text that was there is not a draft any more. */
export function noteDraftSent(sessionId: string | undefined): void {
  if (sessionId?.trim()) chatDraft(sessionId).sent = true;
}

/// Reads the daemon draft: `{ draft }` once acpmux answered (`draft` undefined when it holds none),
/// or undefined when nothing could be read (no session, no page action yet, a failed or dropped
/// connection). "Unread" is never "no draft": a composer that took it for one would let what the
/// person typed while the chat loaded replace acpmux's saved draft.
export async function readDurableDraftState(
  sessionId: string | undefined,
): Promise<{ draft: string | undefined } | undefined> {
  if (!sessionId?.trim()) return undefined;
  try {
    const action = pageDraftAction("chat.readDraft");
    if (!action) return undefined;
    const draft = daemonDraft(await action({ sessionId }));
    return { draft };
  } catch {
    return undefined;
  }
}

/** How long a page about to let go waits for its composer's draft to land (`pane.wakeState`). */
export const DRAFT_SETTLE_MS = 500;

/** Waits for `composer`'s draft to reach the host (``ComposerHandle/settleDraft``), at most `ms`. */
export async function settleDraftWithin(
  composer: { settleDraft(): Promise<void> } | null | undefined,
  ms: number,
): Promise<void> {
  if (!composer) return;
  let timer: ReturnType<typeof setTimeout> | undefined;
  const cap = new Promise<void>((resolve) => {
    timer = setTimeout(resolve, ms);
  });
  await Promise.race([composer.settleDraft().catch(() => undefined), cap]);
  clearTimeout(timer);
}
