import { createContext, useContext } from "react";
import type { SessionInfoSectionId } from "./sessionInfoState";

export type Reorder = {
  dragging: SessionInfoSectionId | undefined;
  start: (id: SessionInfoSectionId, event: React.PointerEvent<HTMLElement>) => void;
  step: (id: SessionInfoSectionId, by: -1 | 1) => void;
};

export const ReorderContext = createContext<Reorder | undefined>(undefined);

/// The panel's reorder actions, for a section inside it; none outside (the gallery's lone sections).
export function useReorder(): Reorder | undefined {
  return useContext(ReorderContext);
}
