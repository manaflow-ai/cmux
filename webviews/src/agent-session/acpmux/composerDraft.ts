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
// WEB-SWAP: a web update's reload waits until acpmux holds every draft (pages/shared/webSwap.ts):
// a reload before a clear lands would bring the old draft back from acpmux. A write that failed or
// timed out stays queued, and each ask retries it, so the hold ends once acpmux answers again. A
// timed-out write that may still land late holds it too (the page repairs that landing), but only
// for `draftWriteLimits.lateHoldMs`, so a request that never answers cannot hold it forever.
holdWebSwap(() => {
  if (pendingDraftWrites.size || flushingDraftWrites) {
    if (!flushingDraftWrites) flushPendingDraftWrites();
    return "composer.draft-unsaved";
  }
  return lateWriteMayLand() ? "composer.draft-unsaved" : null;
});

const WRITE_TIMED_OUT = new Error("chat.writeDraft timed out");

/** How long one draft write may go unanswered before it counts as failed, and how long after that
 * a web swap still waits in case it lands late (tests change them). */
export const draftWriteLimits = { timeoutMs: 5_000, lateHoldMs: 30_000 };

// A write that timed out may still land later, over a newer draft or a clear. Writes keep going
// (a write that never answers holds nothing up); when a late one lands (answers), the newest text
// sent for its session since then goes again, so the newest still lands last. A late refusal landed
// nothing and repairs nothing. An entry goes once every timed-out write of its session has answered.
const lateWrites = new Map<string, { outstanding: number; newer?: string; since: number }>();

function lateWriteMayLand(now = Date.now()): boolean {
  for (const late of lateWrites.values()) if (now - late.since < draftWriteLimits.lateHoldMs) return true;
  return false;
}

function writeTimedOut(sessionId: string, text: string, sent: Promise<unknown>): void {
  const late = lateWrites.get(sessionId) ?? { outstanding: 0, since: 0 };
  late.outstanding += 1;
  late.since = Date.now();
  lateWrites.set(sessionId, late);
  const answered = () => {
    late.outstanding -= 1;
    if (!late.outstanding) lateWrites.delete(sessionId);
  };
  void Promise.resolve(sent).then(
    () => {
      answered();
      const newer = late.newer;
      if (newer === undefined || newer === text || pendingDraftWrites.has(sessionId)) return;
      pendingDraftWrites.set(sessionId, { sessionId, text: newer, sequence: ++draftWriteSequence });
      flushPendingDraftWrites();
    },
    answered,
  );
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
      const next = pendingDraftWrites.entries().next().value as
        | [string, { sessionId: string; text: string; sequence: number }]
        | undefined;
      if (!next) break;
      const [sessionId, write] = next;
      pendingDraftWrites.delete(sessionId);
      let sent: Promise<unknown> | undefined;
      try {
        sent = action({ sessionId: write.sessionId, text: write.text });
        const late = lateWrites.get(sessionId);
        if (late) late.newer = write.text;
        // A write that never answers would keep this drain, and the web-swap hold, forever.
        await answeredInTime(sent);
      } catch (error) {
        if (error === WRITE_TIMED_OUT && sent) writeTimedOut(sessionId, write.text, sent);
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

/** Returns whether a queued write already owns the session's newest value. */
export function hasPendingDraftWrite(sessionId: string | undefined): boolean {
  return Boolean(sessionId && pendingDraftWrites.has(sessionId));
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

/// Stores or clears an unsent prompt in the remount cache and daemon session state.
export function writePersistedDraft(sessionId: string | undefined, text: string): void {
  const key = persistedDraftKey(sessionId);
  if (!key || !sessionId?.trim()) return;
  try {
    if (text.trim()) globalThis.localStorage?.setItem(key, text);
    else globalThis.localStorage?.removeItem(key);
  } catch {
    // A storage failure must never interrupt typing or sending.
  }
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
  if (!sessionId?.trim()) return undefined;
  try {
    const action = pageDraftAction("chat.readDraft");
    return action ? daemonDraft(await action({ sessionId })) : undefined;
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
