// Every gallery entry file: each `*.gallery.ts(x)` under src/ exports one entry by default. The
// glob is LAZY, so each file is its own dynamic import: one broken file (a syntax error, a throw, a
// missing export) fails its own load and no other (entryStore.ts). test/gallery-coverage.test.ts
// reads the same files without Vite (scripts/gallery/entries.ts).
import { createEntryStore, type EntrySource } from "./entryStore";

const loaders = import.meta.glob("../**/*.gallery.{ts,tsx}", { import: "default" });

/** `../agent-session/x.gallery.ts` (relative to this file) as `src/agent-session/x.gallery.ts`. */
export const entryPath = (key: string): string => `src/${key.replace(/^\.\.\//, "")}`;

/** The entry files, by path. A reload (`bust`) imports a fresh copy under a new URL. */
export const entrySources: EntrySource[] = Object.entries(loaders)
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

/** The shell's store: every entry loads on its own. */
export const entryStore = createEntryStore(entrySources);

// The live dev server (dev-server/galleryLive.ts) names the entry files a save changed; each loads
// again on its own, so a fixed file recovers in place with no page reload.
if (import.meta.hot)
  import.meta.hot.on("cmux-gallery:entry", (data: { files: string[]; timestamp: number }) =>
    entryStore.reload(data.files, data.timestamp),
  );
