// The chunks a page fetches once it is idle after its first frame (the facts hover card,
// chips/FactsHoverCard.tsx). Each module that splits one off names its loader here when it loads,
// so whoever needs them all in place can ask for every one at once: the tests do, before a file's
// first test (test/preload.ts), as a page has them by the time anyone points at a card.
const loaders = new Set<() => Promise<unknown>>();

/** `load`, kept with the others. */
export function lazyChunk<T>(load: () => Promise<T>): () => Promise<T> {
  loaders.add(load);
  return load;
}

/** Every chunk named so far, fetched; resolves once all are in. */
export function loadLazyChunks(): Promise<unknown[]> {
  return Promise.all(Array.from(loaders, (load) => load()));
}
