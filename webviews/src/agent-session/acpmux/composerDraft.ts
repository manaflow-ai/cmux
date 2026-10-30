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
 * Draft merge contract (shared vectors: test/fixtures/composer-draft-merge.json): compare exact
 * UTF-16 units, without normalization. Generations default to zero for legacy drafts. The newer
 * generation wins without merging; only equal generations follow the text rule below. Intentional
 * send, clear or replacement advances the generation and persists even an empty tombstone.
 * Blank means ECMAScript trim whitespace. A blank saved
 * side returns typed; otherwise a blank typed side returns saved. Prefer typed if it contains
 * saved, then saved if it contains typed. Otherwise join saved's longest suffix matching typed's
 * prefix (at least two units); with no such overlap, join saved + "\n\n" + typed. Preserve whitespace.
 * Native AgentUnsentDrafts.merged follows this contract and consumes the same fixture.
 */
export function mergedDraft(
  typed: string,
  saved: string | undefined,
  typedGeneration = 0,
  savedGeneration = 0,
): string {
  if (typedGeneration > savedGeneration) return typed;
  if (savedGeneration > typedGeneration) return saved ?? "";
  if (!saved?.trim()) return typed;
  if (!typed.trim()) return saved;
  if (draftMatch(typed, saved).contains) return typed;
  const match = draftMatch(saved, typed);
  if (match.contains) return saved;
  return match.overlap >= 2 ? `${saved}${typed.slice(match.overlap)}` : `${saved}\n\n${typed}`;
}

// KMP: each unit is visited a bounded number of times, including repetitive million-unit drafts.
// The final partial match is precisely the longest suffix of text matching a prefix of pattern.
function draftMatch(text: string, pattern: string): { contains: boolean; overlap: number } {
  const prefix = new Uint32Array(pattern.length);
  for (let index = 1, matched = 0; index < pattern.length; index += 1) {
    while (matched > 0 && pattern[index] !== pattern[matched]) matched = prefix[matched - 1]!;
    if (pattern[index] === pattern[matched]) matched += 1;
    prefix[index] = matched;
  }
  let matched = 0;
  for (let index = 0; index < text.length; index += 1) {
    while (matched > 0 && text[index] !== pattern[matched]) matched = prefix[matched - 1]!;
    if (text[index] === pattern[matched]) matched += 1;
    if (matched === pattern.length) return { contains: true, overlap: matched };
  }
  return { contains: false, overlap: matched };
}

/**
 * What the composer does when acpmux's draft read answers (`readDurableDraftState`).
 * - `firstRead`: this page never read the chat's draft before, so nothing it holds was built on it
 *   (a relaunch, a reload, text typed while the chat loaded). Saved and held text are merged
 *   (`mergedDraft`): an empty or load-time editor never replaces acpmux's non-empty draft, and
 *   typed text is never dropped for it.
 * - Otherwise the page already read it: what the page holds or still has queued is newer (the
 *   person's own edit, a clear included), as before.
 * `text` is the prompt to show, `shown` whether it differs from the editor, and `write` whether it
 * goes to acpmux.
 */
export function hydratedDraft(input: {
  current: string;
  restored: string | undefined;
  edited: boolean;
  pendingWrite: boolean;
  firstRead: boolean;
  generation?: number;
  restoredGeneration?: number;
}): { text: string; shown: boolean; write: boolean } {
  const { current, restored, edited, pendingWrite, firstRead } = input;
  const generation = input.generation ?? 0;
  const restoredGeneration = input.restoredGeneration ?? 0;
  if (generation !== restoredGeneration) {
    const text = mergedDraft(current, restored, generation, restoredGeneration);
    return { text, shown: text !== current, write: generation > restoredGeneration };
  }
  if (firstRead && restored) {
    const text = mergedDraft(current, restored);
    return { text, shown: text !== current, write: text !== restored };
  }
  if (!pendingWrite && restored && !current && !edited) return { text: restored, shown: true, write: false };
  return { text: current, shown: false, write: !pendingWrite && (Boolean(current.trim()) || edited) };
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
const pendingDraftWrites = new Map<string, { sessionId: string; text: string; generation: number; sequence: number }>();
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

type DraftWrite = { sessionId: string; text: string; generation: number; sequence: number };

function staleDraftWrite(error: unknown): boolean {
  if (!error || typeof error !== "object") return false;
  if ("code" in error && error.code === "draft.stale_generation") return true;
  // Compatibility with the first generation-aware daemon, before its structured error code.
  return (
    "message" in error &&
    typeof error.message === "string" &&
    /^stale composer draft generation [0-9]+; current generation is [0-9]+/.test(error.message)
  );
}

function discardStaleDraftWrite(write: DraftWrite): void {
  const pending = pendingDraftWrites.get(write.sessionId);
  // Later edits in the rejected generation are stale too; a send/clear's newer generation stays.
  if (pending && pending.generation <= write.generation) pendingDraftWrites.delete(write.sessionId);
  // Reconcile once, without holding the drain or web swap on another network round trip.
  // Never let this read replace a newer local edit or adopt text from a different generation.
  const sequence = draftWriteSequence;
  void answeredInTime(readDurableDraftState(write.sessionId))
    .then((value) => {
      const state = value as Awaited<ReturnType<typeof readDurableDraftState>>;
      if (!state || draftWriteSequence !== sequence || hasPendingDraftWrite(write.sessionId)) return;
      // A stale write means the daemon advanced this chat while this page was in flight.  Keep
      // that generation in the remount cache: the mounted composer will promote its next edit
      // to it in `writePersistedDraft`, rather than sending another write the daemon must reject.
      // Never replace a newer local cache (or a write that raced this read).
      if (
        state.generation < write.generation ||
        state.generation < readPersistedDraftGeneration(write.sessionId)
      )
        return;
      cachePersistedDraft(write.sessionId, state.draft ?? "", state.generation);
    })
    .catch(() => undefined);
}

function writeTimedOut(action: DraftAction, write: DraftWrite, sent: Promise<unknown>): void {
  const { sessionId, sequence } = write;
  const late = { action, since: Date.now() };
  unansweredWrite = late;
  const answered = () => {
    if (unansweredWrite !== late) return;
    unansweredWrite = undefined;
    flushPendingDraftWrites();
  };
  void Promise.resolve(sent).then(
    () => {
      // It landed: its own retry, still queued, would only land over a later edit.
      if (pendingDraftWrites.get(sessionId)?.sequence === sequence) pendingDraftWrites.delete(sessionId);
      answered();
    },
    (error) => {
      if (staleDraftWrite(error)) discardStaleDraftWrite(write);
      answered();
    },
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
      if (unansweredWrite?.action !== action) unansweredWrite = undefined;
      // A write that timed out may still land: anything newer waits for its answer (writeTimedOut).
      if (unansweredWrite) break;
      const next = pendingDraftWrites.entries().next().value as
        | [string, { sessionId: string; text: string; generation: number; sequence: number }]
        | undefined;
      if (!next) break;
      const [sessionId, write] = next;
      pendingDraftWrites.delete(sessionId);
      let sent: Promise<unknown> | undefined;
      try {
        sent = action({ sessionId: write.sessionId, text: write.text, generation: write.generation });
        // A write that never answers would keep this drain, and the web-swap hold, forever.
        await answeredInTime(sent);
      } catch (error) {
        if (staleDraftWrite(error)) {
          discardStaleDraftWrite(write);
          continue;
        }
        if (error === WRITE_TIMED_OUT && sent) writeTimedOut(action, write, sent);
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

/** A persisted generation is a nonnegative safe integer; old text-only drafts belong to zero. */
export function draftGeneration(value: unknown): number {
  return typeof value === "number" && Number.isSafeInteger(value) && value >= 0 ? value : 0;
}

export type DraftVersionKnowledge = { known: boolean; pendingReplacement: boolean };
export function readPersistedDraftState(
  sessionId: string | undefined,
): { text: string; generation: number } & DraftVersionKnowledge {
  const key = persistedDraftKey(sessionId);
  if (!key) return { text: "", generation: 0, known: false, pendingReplacement: false };
  try {
    const raw = globalThis.localStorage?.getItem(`${key}.state-v1`);
    if (raw != null) {
      const state = JSON.parse(raw) as {
        text?: unknown;
        generation?: unknown;
        known?: boolean;
        pendingReplacement?: boolean;
      };
      return {
        text: typeof state.text === "string" ? state.text : "",
        generation: draftGeneration(state.generation),
        known: state.known !== false,
        pendingReplacement: state.pendingReplacement === true,
      };
    }
    const text = globalThis.localStorage?.getItem(key);
    return { text: text ?? "", generation: 0, known: text != null, pendingReplacement: false };
  } catch {
    return { text: "", generation: 0, known: false, pendingReplacement: false };
  }
}

export function readPersistedDraftVersion(sessionId: string | undefined): DraftVersionKnowledge {
  const { known, pendingReplacement } = readPersistedDraftState(sessionId);
  return { known, pendingReplacement };
}

export function readPersistedDraftGeneration(sessionId: string | undefined): number {
  return readPersistedDraftState(sessionId).generation;
}

/// Reads the last unsent prompt from the page's synchronous remount cache.
export function readPersistedDraft(sessionId: string | undefined): string | undefined {
  return composerDraft(readPersistedDraftState(sessionId).text);
}

/// Text and generation commit atomically, including empty tombstones after a clear or send.
export function cachePersistedDraft(
  sessionId: string | undefined,
  text: string,
  generation = readPersistedDraftGeneration(sessionId),
  knowledge = readPersistedDraftVersion(sessionId),
): void {
  const key = persistedDraftKey(sessionId);
  if (!key || generation < readPersistedDraftGeneration(sessionId)) return;
  try {
    globalThis.localStorage?.setItem(`${key}.state-v1`, JSON.stringify({ text, generation, ...knowledge }));
    globalThis.localStorage?.removeItem(key);
  } catch {
    // A storage failure must never interrupt typing or sending.
  }
}

/// Stores or clears an unsent prompt in the remount cache and daemon session state.
export function writePersistedDraft(
  sessionId: string | undefined,
  text: string,
  generation = readPersistedDraftGeneration(sessionId),
  knowledge = readPersistedDraftVersion(sessionId),
): void {
  if (!sessionId?.trim()) return;
  // A stale-generation rejection can arrive after the mounted composer has already learned the
  // daemon's newer state.  Promote this edit to the cached generation so the next write is accepted.
  const effectiveGeneration = Math.max(generation, readPersistedDraftGeneration(sessionId));
  cachePersistedDraft(sessionId, text, effectiveGeneration, knowledge);
  pendingDraftWrites.set(sessionId, {
    sessionId,
    text,
    generation: effectiveGeneration,
    sequence: ++draftWriteSequence,
  });
  if (text) lastQueuedDraft.set(sessionId, text);
  else lastQueuedDraft.delete(sessionId);
  flushPendingDraftWrites();
}

/// Reads the daemon draft; a missing page action is expected in browser-only and test hosts.
export async function readDurableDraft(sessionId: string | undefined): Promise<string | undefined> {
  return (await readDurableDraftState(sessionId))?.draft;
}

/// Reads the daemon draft: `{ draft }` once acpmux answered (`draft` undefined when it holds none),
/// or undefined when nothing could be read (no session, no page action yet, a failed or dropped
/// connection). "Unread" is never "no draft": a composer that took it for one would let what the
/// person typed while the chat loaded replace acpmux's saved draft.
export async function readDurableDraftState(
  sessionId: string | undefined,
): Promise<{ draft: string | undefined; generation: number } | undefined> {
  if (!sessionId?.trim()) return undefined;
  try {
    const action = pageDraftAction("chat.readDraft");
    if (!action) return undefined;
    const result = await action({ sessionId });
    const generation = draftGeneration(
      result && typeof result === "object" && "generation" in result ? result.generation : 0,
    );
    return { draft: daemonDraft(result), generation };
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
