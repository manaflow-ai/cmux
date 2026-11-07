import { memo } from "react";
import { useT } from "../i18n";
import { type RowProps } from "./rowProps";

export const ReadOnlyPermissionRow = memo(
  function ReadOnlyPermissionRow({ row }: RowProps) {
    const t = useT();
    return <div className="acpmux-muted">{row.permission?.title?.trim() || t("permission.required")}</div>;
  },
  (a, b) => a.row.id === b.row.id && a.row.version === b.row.version,
);
