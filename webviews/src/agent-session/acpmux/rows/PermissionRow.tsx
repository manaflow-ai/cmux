// The `permission` row: an ask in the transcript.
import { memo } from "react";
import { useT } from "../i18n";
import { PermissionAsk } from "./PermissionAsk";
import type { RowProps } from "./rowProps";

export const PermissionRow = memo(
  function PermissionRow({ row }: RowProps) {
    const t = useT();
    const permission = row.permission;
    if (!permission)
      return (
        <div className="acpmux-permission-card">
          <strong>{t("permission.required")}</strong>
        </div>
      );
    return <PermissionAsk permission={permission} shortcuts={false} />;
  },
  (a, b) => a.row.id === b.row.id && a.row.version === b.row.version,
);
