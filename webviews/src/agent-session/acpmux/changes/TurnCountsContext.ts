// The edited-files cards' totals come from the turn's checkpoint once it has loaded. The pane
// provides the lookup, so a card reads it without holding the transcript.
import { createContext } from "react";
import type { TurnFile } from "../diff";
import type { turnCounts } from "./turnCheckpoint";

export type TurnCountsFor = (rowId: string, toolFiles: readonly TurnFile[]) => ReturnType<typeof turnCounts>;

export const TurnCountsContext = createContext<TurnCountsFor | undefined>(undefined);
