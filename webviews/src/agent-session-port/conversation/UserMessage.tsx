import type { ReactNode } from "react";
import { IconButton } from "./buttons";
import { Copy, Pencil } from "./icons";

export type UserMessageProps = {
  children: ReactNode;
  /** Copy / edit buttons under the bubble (shown on hover or after a stop; the row's space is always reserved). */
  actions?: boolean;
};

/** Right-aligned user bubble (max 70% of the column). */
export function UserMessage({ children, actions = false }: UserMessageProps) {
  return (
    <div className="cv-user">
      <div className="cv-user__bubble">{children}</div>
      <div className="cv-user__actions">
        {actions && (
          <>
            <IconButton label="Copy message">
              <Copy />
            </IconButton>
            <IconButton label="Edit message">
              <Pencil />
            </IconButton>
          </>
        )}
      </div>
    </div>
  );
}
