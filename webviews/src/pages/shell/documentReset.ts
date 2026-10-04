// What `page.reset` clears so the next shell page sees nothing of the last one: Web Storage,
// IndexedDB, Cache Storage, every global not in the shell's snapshot, every node added to <head>,
// the page root, the title and the language. One reset runs before a new page mounts.

/** The document state a reset restores (taken at shell boot). */
export interface DocumentSnapshot {
  readonly globals: Set<string>;
  readonly head: Set<Node>;
  readonly title: string;
  readonly lang: string;
}

/** The parts of `window` a reset touches; tests pass a jsdom window with stand-ins. */
export interface ShellWindow {
  readonly document: Document;
  readonly localStorage?: Storage;
  readonly sessionStorage?: Storage;
  readonly indexedDB?: Pick<IDBFactory, "deleteDatabase"> & { databases?: () => Promise<{ name?: string }[]> };
  readonly caches?: Pick<CacheStorage, "keys" | "delete">;
}

export function snapshotDocument(win: ShellWindow): DocumentSnapshot {
  return {
    globals: new Set(Object.getOwnPropertyNames(win)),
    head: new Set(Array.from(win.document.head.childNodes)),
    title: win.document.title,
    lang: win.document.documentElement.lang,
  };
}

/** Adds globals defined since the snapshot (a page module's own top-level code, loaded once). */
export function extendSnapshot(win: ShellWindow, snapshot: DocumentSnapshot): void {
  for (const name of Object.getOwnPropertyNames(win)) snapshot.globals.add(name);
}

/** Globals defined since the snapshot. */
export function addedGlobals(win: ShellWindow, snapshot: DocumentSnapshot): string[] {
  return Object.getOwnPropertyNames(win).filter((name) => !snapshot.globals.has(name));
}

/**
 * Clears the synchronous state at once (storage, globals, DOM, title, lang) and returns a promise
 * for the asynchronous stores (IndexedDB, Cache Storage). The next page may mount before that
 * promise settles: the deletes are queued first, so its own opens run after them.
 */
export function resetDocument(win: ShellWindow, snapshot: DocumentSnapshot, root: Element): Promise<void> {
  safely(() => win.localStorage?.clear());
  safely(() => win.sessionStorage?.clear());
  const record = win as unknown as Record<string, unknown>;
  for (const name of addedGlobals(win, snapshot)) {
    safely(() => {
      delete record[name];
    });
  }
  root.replaceChildren();
  for (const node of Array.from(win.document.head.childNodes)) {
    if (!snapshot.head.has(node)) node.parentNode?.removeChild(node);
  }
  win.document.title = snapshot.title;
  win.document.documentElement.lang = snapshot.lang;
  return Promise.all([clearIndexedDB(win), clearCaches(win)]).then(() => undefined);
}

async function clearIndexedDB(win: ShellWindow): Promise<void> {
  const factory = win.indexedDB;
  if (!factory?.databases) return;
  const databases = await factory.databases().catch(() => []);
  // Each delete settles on success, error or blocked (an open connection of the old page delays
  // the delete itself; the next page's opens queue behind it).
  await Promise.all(
    databases.map(
      (database) =>
        new Promise<void>((resolve) => {
          if (!database.name) return resolve();
          try {
            const request = factory.deleteDatabase(database.name);
            request.onsuccess = request.onerror = request.onblocked = () => resolve();
          } catch {
            resolve();
          }
        }),
    ),
  );
}

async function clearCaches(win: ShellWindow): Promise<void> {
  const caches = win.caches;
  if (!caches) return;
  const keys = await caches.keys().catch(() => [] as string[]);
  await Promise.all(keys.map((key) => caches.delete(key).catch(() => false)));
}

function safely(action: () => unknown): void {
  try {
    action();
  } catch {
    // A store the engine refuses (no storage for this origin) has nothing to clear.
  }
}
