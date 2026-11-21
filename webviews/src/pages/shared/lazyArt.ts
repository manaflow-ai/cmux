// Art a page draws as a data URL (the pages' CSP allows `img-src data:` only, so bundle.mjs inlines
// each PNG), kept out of the page's first load. A PNG imported statically ships as base64 inside the
// page's own chunk, parsed before the page draws anything; behind `import()` it is a chunk of its own.
// The import starts when the page's module calls `lazyArt`, right after the page's chunk, so the art
// is in long before a person reaches what draws it; until then an img draws a transparent pixel, which
// keeps its box and shows no alt text.
import { useSyncExternalStore } from "react";

/** A transparent pixel: what an img draws for the moment before its art is in. */
export const NO_ART = "data:image/gif;base64,R0lGODlhAQABAIAAAAAAAP///yH5BAEAAAAALAAAAAABAAEAAAIBRAA7";

export interface LazyArt<T> {
  /** The art once it is in, else null. */
  use(): T | null;
  /** Resolves once the art is in (or failed to load, which leaves `use` at null). */
  loaded: Promise<void>;
}

/** Starts `load` now and gives a hook that redraws its component once the art is in. */
export function lazyArt<T>(load: () => Promise<T>): LazyArt<T> {
  let value: T | null = null;
  const listeners = new Set<() => void>();
  const loaded = load().then(
    (art) => {
      value = art;
      for (const listener of listeners) listener();
    },
    () => undefined,
  );
  const subscribe = (listener: () => void) => {
    listeners.add(listener);
    return () => void listeners.delete(listener);
  };
  const read = () => value;
  return { use: () => useSyncExternalStore(subscribe, read, read), loaded };
}
