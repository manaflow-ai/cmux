import type { ReactNode } from "react";
import { TurnActions, type TurnActionsKind } from "./TurnActions";

/** Assistant turn wrapper; `actions` closes the turn with its button row. */
export function AssistantMessage({ children, actions }: { children: ReactNode; actions?: TurnActionsKind }) {
  return (
    <div className="cv-assistant">
      {children}
      {actions && <TurnActions kind={actions} />}
    </div>
  );
}
