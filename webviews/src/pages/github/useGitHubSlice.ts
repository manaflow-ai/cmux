// One slice of the GitHub page's snapshot, read through `useSyncExternalStore` with a selector, so a
// component draws again only when its own slice changes (TkDodo, "React Query Selectors, Supercharged":
// a component subscribes to the part of the data it uses). The store keeps every field it did not
// change by reference (store.ts `set({ ...this.snapshot, ... })`), so a file's patch streaming in leaves
// the conversation, the header and the checks still; before, every part took the whole snapshot.
import { useSyncExternalStore } from "react";
import type { GitHubSnapshot, GitHubStore } from "./store";

export function useGitHubSlice<T>(store: GitHubStore, select: (snapshot: GitHubSnapshot) => T): T {
  const read = () => select(store.getSnapshot());
  return useSyncExternalStore(store.subscribe, read, read);
}
