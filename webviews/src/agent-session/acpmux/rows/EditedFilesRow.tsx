// The edited-files row (an edit's `activity` row).
import { memo } from "react";
import { EditedFilesCard } from "../conversation/EditedFilesCard";
import type { RowProps } from "./rowProps";

/// The edited-files card (conversation/EditedFilesCard.tsx, data in turnChanges/).
export const EditedFilesRow = memo(
  function EditedFilesRow({ row, sessionId, onOpenDiff }: RowProps) {
    return <EditedFilesCard row={row} sessionId={sessionId} onOpenDiff={onOpenDiff} />;
  },
  (a, b) =>
    a.row.id === b.row.id &&
    a.row.version === b.row.version &&
    a.sessionId === b.sessionId &&
    a.onOpenDiff === b.onOpenDiff,
);
