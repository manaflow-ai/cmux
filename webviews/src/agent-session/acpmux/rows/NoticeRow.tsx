import { memo } from "react";
import { ForkedFromLine } from "../conversation/ForkedFromLine";
import { type RowProps } from "./rowProps";

export const NoticeRow = memo(
  function NoticeRow({ row }: RowProps) {
    // A fork's "Forked from <chat>" line links the chat it came from (#50086).
    if (row.forkedFrom && row.text) return <ForkedFromLine text={row.text} forkedFrom={row.forkedFrom} />;
    return <div className="acpmux-muted">{row.text}</div>;
  },
  (a, b) => a.row.id === b.row.id && a.row.version === b.row.version,
);
