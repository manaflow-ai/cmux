/**
 * A new chat's inherited draft (a terminal selection, a page's URL), or undefined when
 * the handshake carries none. It is shown in the composer, never sent by itself.
 */
export function composerDraft(draft: unknown): string | undefined {
  return typeof draft === "string" && draft.trim() ? draft : undefined;
}

/** The composer text once a draft arrives: the draft, unless the user already typed something. */
export function seededText(current: string, draft: string | undefined): string {
  return draft && !current ? draft : current;
}

const PERSISTED_DRAFT_PREFIX = "cmux.acpmux.composer-draft.";

function persistedDraftKey(sessionId: string | undefined): string | undefined {
  if (!sessionId?.trim()) return undefined;
  return `${PERSISTED_DRAFT_PREFIX}${encodeURIComponent(sessionId)}`;
}

/// Reads the last unsent prompt for a durable agent session. The browser profile is the
/// client-owned store here, so a normal quit or app relaunch keeps the draft without putting
/// prompt text in the daemon's shared session record.
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

/// Stores or clears an unsent prompt for a durable agent session.
export function writePersistedDraft(sessionId: string | undefined, text: string): void {
  const key = persistedDraftKey(sessionId);
  if (!key) return;
  try {
    if (text.trim()) globalThis.localStorage?.setItem(key, text);
    else globalThis.localStorage?.removeItem(key);
  } catch {
    // A storage failure must never interrupt typing or sending.
  }
}
