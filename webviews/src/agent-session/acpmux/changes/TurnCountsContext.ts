// The edited-files cards' totals come from the turn's checkpoint once it has loaded. The pane
// provides the lookup, so a card reads it without holding the transcript.
import { createContext } from "react";
import type { PathRef, TurnFile } from "../diff";
import type { turnCounts } from "./turnCheckpoint";

/// `pathsOnly`: paths the turn's edits changed without a counted diff (diff.ts `turnPathsOnly`).
export type TurnCountsFor = (
  rowId: string,
  toolFiles: readonly TurnFile[],
  pathsOnly?: readonly PathRef[],
) => ReturnType<typeof turnCounts>;

export const TurnCountsContext = createContext<TurnCountsFor | undefined>(undefined);
