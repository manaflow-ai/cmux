import { useSyncExternalStore } from "react";

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
const pendingDraftWrites = new Map<string, { sessionId: string; text: string; sequence: number }>();

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
  void flushDraftWrites();
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
      try {
        await action({ sessionId: write.sessionId, text: write.text });
      } catch {
        // A disconnect can invalidate the action while it is in flight. Keep the newest value
        // for the next connection, while preserving a later keystroke already in the queue.
        const current = pendingDraftWrites.get(sessionId);
        if (!current || current.sequence === write.sequence) pendingDraftWrites.set(sessionId, write);
        break;
      }
    }
  } finally {
    flushingDraftWrites = false;
    if (pendingDraftWrites.size && pageDraftAction("chat.writeDraft")) void flushDraftWrites();
  }
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
  void flushDraftWrites();
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
