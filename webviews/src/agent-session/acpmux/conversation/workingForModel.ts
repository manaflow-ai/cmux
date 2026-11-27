import { createContext } from "react";
import type { TurnTokenSplit } from "../model";
import { previewAddress } from "./previewChipModel";

/// What the running turn's line says after its time (App.tsx). The running subagents, background
/// commands and started chats are the tray's to count (subagents/runningTray.ts), never the line's.
export type WorkingCounts = {
  /// The turn's generated output tokens so far (snapshot `turnTokens`), when the harness reports them.
  tokens?: number;
  /// Those tokens split into output and what the calls read (snapshot `turnTokenSplit`), when known.
  split?: TurnTokenSplit;
  /// The page the newest running background command serves (PreviewChip.tsx), and what opens it.
  preview?: { url: string; open: () => void };
};

export { workingTokens } from "./turnTokensModel";

/// What follows the running line's time, each opening what it names: the page a background command
/// serves (`localhost:5173`), which opens it beside the chat.
export function workingParts(counts: WorkingCounts): { key: string; label: string; open: () => void }[] {
  return counts.preview === undefined
    ? []
    : [{ key: "preview", label: previewAddress(counts.preview.url), open: counts.preview.open }];
}

export const WorkingCountsContext = createContext<WorkingCounts | undefined>(undefined);
