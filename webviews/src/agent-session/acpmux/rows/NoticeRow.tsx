import { memo } from "react";
import { useT } from "../i18n";
import { type RowProps } from "./rowProps";

export const NoticeRow = memo(
  function NoticeRow({ row }: RowProps) {
    const t = useT();
    return (
      <div className="acpmux-muted">
        {row.kind === "shadowReview" ? t("shadowReview.logged", { goal: row.text ?? "" }) : row.text}
      </div>
    );
  },
  (a, b) => a.row.id === b.row.id && a.row.version === b.row.version,
);
