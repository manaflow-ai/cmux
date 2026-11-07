// How a background command's row elsewhere (Session Info's Background tasks list) opens it rendered:
// the chat's Background tasks panel (BackgroundTasksPanel.tsx), where it is a card with its command
// and its output, instead of a bare terminal tab (Leo, 2026-11-07: "only showing the terminal
// thing, I don't think is very useful"). App.tsx provides it; unset (the gallery, Quick Chat), a
// row opens what it opened before.
import { createContext } from "react";

export const OpenBackgroundTasks = createContext<(() => void) | undefined>(undefined);
