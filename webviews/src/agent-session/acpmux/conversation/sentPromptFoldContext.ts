import { createContext } from "react";

/// The sent prompt a pick's chip is drawn in (PromptText.tsx): its row, whether its fold is shut, and
/// how to open it. None outside a transcript's prompt (a gallery, a test of the chip alone).
export type SentPromptFold = { rowId: string; collapsed: boolean; open: () => void };
export const SentPromptFoldContext = createContext<SentPromptFold | undefined>(undefined);
