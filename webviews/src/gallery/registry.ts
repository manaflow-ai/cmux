// Every gallery entry file: each `*.gallery.ts(x)` under src/ exports one entry by default. The
// glob is LAZY, so each file is its own dynamic import: one broken file (a syntax error, a throw, a
// missing export) fails its own load and no other (entryStore.ts). test/gallery-coverage.test.ts
// reads the same files without Vite (scripts/gallery/entries.ts).
import { createEntryStore, entryPath, type EntrySource, type EntryStore } from "./entryStore";
// Bun's types also declare import.meta.hot (with argument-less listeners); these listeners are Vite's.
import type { ViteHotContext } from "vite/types/hot.d.ts";

const loaders = import.meta.glob("../**/*.gallery.{ts,tsx}", { import: "default" });

/** The entry files, by path. A reload (`bust`) imports a fresh copy under a new URL. */
const allEntrySources: EntrySource[] = Object.entries(loaders)
  .sort(([a], [b]) => a.localeCompare(b))
  .map(([key, load]) => ({
    path: entryPath(key),
    load: (bust?: number) =>
      bust === undefined
        ? load()
        : import(/* @vite-ignore */ `${new URL(key, import.meta.url).pathname}?t=${bust}`).then(
            (module: { default?: unknown }) => module.default,
          ),
  }));

// Stage frames can opt into one entry path so browser tests do not cold-load the entire
// gallery registry before exercising a single page. The shell omits this query and retains
// the complete registry.
const requestedEntryPath =
  typeof location === "undefined" ? undefined : new URLSearchParams(location.search).get("entryPath");
export const entrySources = requestedEntryPath
  ? allEntrySources.filter((source) => source.path === requestedEntryPath)
  : allEntrySources;

/** The shell's store: every entry loads on its own. Created only when the shell mounts. */
let shellStore: EntryStore | undefined;
export function getEntryStore(): EntryStore {
  return (shellStore ??= createEntryStore(entrySources));
}

/** A frame store loads only the source named by the shell; stale source links fail explicitly. */
export function createFrameEntryStore(sourcePath?: string): EntryStore {
  const sources = sourcePath ? entrySources.filter((source) => source.path === sourcePath) : entrySources;
  return createEntryStore(sources);
}

// The live dev server (dev-server/galleryLive.ts) names the entry files a save changed; each loads
// again on its own, so a fixed file recovers in place with no page reload.
if (import.meta.hot)
  (import.meta.hot as unknown as ViteHotContext).on(
    "cmux-gallery:entry",
    (data: { files: string[]; timestamp: number }) => getEntryStore().reload(data.files, data.timestamp),
  );
