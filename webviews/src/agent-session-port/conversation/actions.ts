// Actions a transcript card can take on its turn (the edited-files card's View changes).
// A context, so the ported renderer needs no prop threading through every turn.
import { createContext } from "react";

export type ChatActions = { viewChanges?: (turnId: string) => void };

export const ChatActionsContext = createContext<ChatActions>({});
