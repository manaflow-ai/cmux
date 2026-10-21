// The import suggestion cards for the New Tab page, as the host pushes them (`importCards`,
// CmuxNextAgentPane AgentPaneImportCards): a few cards for what this Mac has that cmux can bring
// over, or null while there are none or the cards are off (Debug Settings
// `browserImport.suggestionCards`). A module store like newtab/nowPlaying.ts, so a push that
// arrives before the screen mounts is kept.
import { useSyncExternalStore } from "react";
import { parseImportCards, type ImportCardList } from "../../ui/ImportCards";

let list: ImportCardList | null = null;
const listeners = new Set<() => void>();

/// Replaces the cards from a host push; anything malformed clears them.
export function setImportCards(value: unknown): void {
  list = parseImportCards(value);
  for (const listener of listeners) listener();
}

export function importCards(): ImportCardList | null {
  return list;
}

function subscribe(listener: () => void): () => void {
  listeners.add(listener);
  return () => listeners.delete(listener);
}

export function useImportCards(): ImportCardList | null {
  return useSyncExternalStore(subscribe, importCards, importCards);
}
