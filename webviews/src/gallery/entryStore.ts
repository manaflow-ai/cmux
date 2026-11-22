// The gallery's entries as separate, independently failing loads. Each `*.gallery.ts(x)` file is
// one dynamic import (registry.ts), so a syntax error, a type-strip error, a throw at module
// evaluation or a missing default export breaks that entry alone: the shell shows its error card
// and every other entry keeps working. A reload (the live dev server's `cmux-gallery:entry` event
// after a save) replaces one entry's load, so a fixed file recovers with no page reload.
//
// Plain TypeScript, no Vite: the shell (shell/), the stage frames (frame/main.ts) and the tests
// drive the same store.
import { validateEntries, type GalleryEntry } from "./format";

/** One entry file: its path under webviews (`src/agent-session/x.gallery.ts`) and its loader. */
export type EntrySource = {
  path: string;
  /** The module's default export. `bust` asks for a fresh copy of the module (a new URL). */
  load: (bust?: number) => Promise<unknown>;
};

/**
 * A promise React's `use` reads synchronously once settled: React 19 reads the `status`, `value`
 * and `reason` fields it finds on a thenable, so a loaded entry renders with no Suspense flash.
 */
export type TrackedPromise<T> = Promise<T>;
type Fields<T> = { status?: "pending" | "fulfilled" | "rejected"; value?: T; reason?: unknown };

export type EntryState = {
  path: string;
  /** Bumped by every reload: a new load, and a new key for the entry's error boundary. */
  version: number;
  status: "loading" | "ready" | "error";
  promise: TrackedPromise<GalleryEntry>;
  entry?: GalleryEntry;
  /** The last entry this file loaded: keeps its place (area, id) in the shell while it is broken. */
  lastGood?: GalleryEntry;
  error?: unknown;
};

/** An entry file that loaded but is not a usable entry. */
export class EntryShapeError extends Error {
  override name = "EntryShapeError";
}

/** Checks a module's default export: an object with an id, an area, a title and variants. */
export function checkEntry(path: string, value: unknown): GalleryEntry {
  if (!value || typeof value !== "object")
    throw new EntryShapeError(`${path} has no default export (export default an entry from format.ts)`);
  const entry = value as GalleryEntry;
  for (const key of ["id", "title", "area", "host"] as const)
    if (typeof entry[key] !== "string") throw new EntryShapeError(`${path}: the entry has no ${key}`);
  if (!entry.variants || typeof entry.variants !== "object") throw new EntryShapeError(`${path}: no variants`);
  if (!Array.isArray(entry.covers)) throw new EntryShapeError(`${path}: no covers`);
  const problems = validateEntries([entry]);
  if (problems.length) throw new EntryShapeError(problems.join("\n"));
  return entry;
}

function track<T>(promise: Promise<T>): TrackedPromise<T> {
  const tracked = promise as Promise<T> & Fields<T>;
  tracked.status = "pending";
  promise.then(
    (value) => {
      tracked.status = "fulfilled";
      tracked.value = value;
    },
    (reason: unknown) => {
      tracked.status = "rejected";
      tracked.reason = reason;
    },
  );
  return tracked;
}

export type EntryStore = ReturnType<typeof createEntryStore>;

export function createEntryStore(sources: readonly EntrySource[]) {
  const listeners = new Set<() => void>();
  const states = new Map<string, EntryState>();
  let snapshot: readonly EntryState[] = [];
  const publish = () => {
    snapshot = sources.map((source) => states.get(source.path)!);
    for (const listener of listeners) listener();
  };

  const start = (source: EntrySource, bust?: number) => {
    const previous = states.get(source.path);
    const version = (previous?.version ?? 0) + 1;
    const promise = track(
      Promise.resolve()
        .then(() => source.load(bust))
        .then((value) => checkEntry(source.path, value)),
    );
    // Swallowed here; the state carries the error, and `use` rethrows it into the entry's boundary.
    promise.catch(() => undefined);
    const state: EntryState = {
      path: source.path,
      version,
      status: "loading",
      promise,
      lastGood: previous?.lastGood ?? previous?.entry,
    };
    states.set(source.path, state);
    void promise.then(
      (entry) => {
        if (states.get(source.path) !== state) return;
        states.set(source.path, { ...state, status: "ready", entry, lastGood: entry });
        publish();
      },
      (error: unknown) => {
        if (states.get(source.path) !== state) return;
        states.set(source.path, { ...state, status: "error", error });
        publish();
      },
    );
    return promise;
  };

  for (const source of sources) void start(source);
  publish();

  return {
    subscribe(listener: () => void): () => void {
      listeners.add(listener);
      return () => listeners.delete(listener);
    },
    getSnapshot: (): readonly EntryState[] => snapshot,
    /** Loads these files again (fresh module copies), each on its own. */
    reload(paths: readonly string[], bust = Date.now()): void {
      let changed = false;
      for (const source of sources)
        if (paths.includes(source.path)) {
          void start(source, bust);
          changed = true;
        }
      if (changed) publish();
    },
    /** Resolves once no entry is loading (failed ones count as settled). */
    async settled(): Promise<readonly EntryState[]> {
      for (;;) {
        const current = snapshot;
        await Promise.allSettled(current.map((state) => state.promise));
        if (snapshot.every((state) => state.status !== "loading")) return snapshot;
      }
    },
  };
}

/** The ready entries, sorted by area and title (the order the shell lists them in). */
export function readyEntries(states: readonly EntryState[]): GalleryEntry[] {
  return states
    .flatMap((state) => (state.status === "ready" && state.entry ? [state.entry] : []))
    .sort((a, b) => a.area.localeCompare(b.area) || a.title.localeCompare(b.title));
}

/** The message an error card shows: the dev server's compile error when it sent one, else the error. */
export function errorText(error: unknown): string {
  if (error instanceof Error)
    return error.stack && !error.stack.startsWith(error.message)
      ? `${error.message}\n${error.stack}`
      : (error.stack ?? error.message);
  return String(error);
}
