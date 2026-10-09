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
let nativeWrite: Promise<void> = Promise.resolve();

function persistedDraftKey(sessionId: string | undefined): string | undefined {
  if (!sessionId?.trim()) return undefined;
  return `${PERSISTED_DRAFT_PREFIX}${encodeURIComponent(sessionId)}`;
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

/// Stores or clears an unsent prompt in the remount cache and app-owned native store.
export function writePersistedDraft(sessionId: string | undefined, text: string): void {
  const key = persistedDraftKey(sessionId);
  if (!key) return;
  try {
    if (text.trim()) globalThis.localStorage?.setItem(key, text);
    else globalThis.localStorage?.removeItem(key);
  } catch {
    // A storage failure must never interrupt typing or sending.
  }
  // The app-owned bridge is the durable store. Keep writes ordered because each keystroke queues
  // an async page-host call, while localStorage remains the synchronous remount cache.
  void import("./native")
    .then(({ postNative }) => {
      nativeWrite = nativeWrite
        .catch(() => undefined)
        .then(() => postNative("chat.writeDraft", { sessionId, text }).then(() => undefined));
      return nativeWrite;
    })
    .catch(() => undefined);
}

/// Reads the app-owned draft; a missing bridge is expected in browser-only and test hosts.
export async function readNativePersistedDraft(sessionId: string | undefined): Promise<string | undefined> {
  if (!sessionId?.trim()) return undefined;
  try {
    const { postNative } = await import("./native");
    return composerDraft(await postNative("chat.readDraft", { sessionId }));
  } catch {
    return undefined;
  }
}
