import { memo } from "react";
import { ForkDividerLine } from "../conversation/ForkDividerLine";
import { openForkInTab } from "./rowActions";
import { type RowProps } from "./rowProps";

export const NoticeRow = memo(
  function NoticeRow({ row }: RowProps) {
    // A fork's cut (conversation/forkDivider.ts): the divider, not a sentence.
    if (row.forkDivider) return <ForkDividerLine divider={row.forkDivider} onOpenInTab={openForkInTab} />;
    return <div className="acpmux-muted">{row.text}</div>;
  },
  (a, b) =>
    a.row.id === b.row.id &&
    a.row.version === b.row.version &&
    a.row.forkDivider?.label === b.row.forkDivider?.label &&
    a.row.forkDivider?.openInTab?.sessionId === b.row.forkDivider?.openInTab?.sessionId &&
    a.row.forkDivider?.openInTab?.parentId === b.row.forkDivider?.openInTab?.parentId,
);
