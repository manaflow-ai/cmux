// `agentPane.editedFiles.*` in cmux.json (Swift CmuxNextSettings EditedFilesSettings), pushed by
// the host as the `editedFiles` event: whether the card shows (always, collapsed to its header, or
// never, which leaves the plain tool rows), how many file rows show before "Show N more", and
// whether a card covers one turn or the whole session (one card, at the latest edit).
import { useSyncExternalStore } from "react";

export type EditedFilesShow = "always" | "collapsed" | "never";
export type EditedFilesScope = "turn" | "session";
export type EditedFilesSettings = { show: EditedFilesShow; maxRows: number; scope: EditedFilesScope };

export const DEFAULT_EDITED_FILES: EditedFilesSettings = { show: "always", maxRows: 5, scope: "turn" };
/// The host's range for maxRows (the schema's).
export const MAX_ROWS_RANGE = { min: 1, max: 50 } as const;

/// The host's value; anything it does not know keeps the default.
export function readEditedFilesSettings(value: unknown): EditedFilesSettings {
  const raw = (value && typeof value === "object" ? value : {}) as Record<string, unknown>;
  const show = raw.show === "collapsed" || raw.show === "never" ? raw.show : DEFAULT_EDITED_FILES.show;
  const scope = raw.scope === "session" ? "session" : DEFAULT_EDITED_FILES.scope;
  const rows = raw.maxRows;
  const maxRows =
    typeof rows === "number" && Number.isInteger(rows) && rows >= MAX_ROWS_RANGE.min && rows <= MAX_ROWS_RANGE.max
      ? rows
      : DEFAULT_EDITED_FILES.maxRows;
  return { show, maxRows, scope };
}

let current = DEFAULT_EDITED_FILES;
const listeners = new Set<() => void>();

export function setEditedFilesSettings(value: unknown) {
  const next = readEditedFilesSettings(value);
  if (next.show === current.show && next.maxRows === current.maxRows && next.scope === current.scope) return;
  current = next;
  for (const listener of listeners) listener();
}

export function useEditedFilesSettings(): EditedFilesSettings {
  return useSyncExternalStore(
    (listener) => {
      listeners.add(listener);
      return () => listeners.delete(listener);
    },
    () => current,
  );
}

declare global {
  interface Window {
    /// The old host's script for the `editedFiles` event (CmuxNextAgentPane AgentPaneView).
    cmuxAcpmuxEditedFiles?: (value: unknown) => void;
  }
}
if (typeof window !== "undefined") window.cmuxAcpmuxEditedFiles = setEditedFilesSettings;
