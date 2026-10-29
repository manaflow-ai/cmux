// The `permissionRecord` row: a single permission card's receipt.
import { memo } from "react";
import { useT } from "../i18n";
import { AnsweredBy } from "../multiplayer/Faces";
import { DECISION_TEXT } from "../permissions/record";
import type { RowProps } from "./rowProps";

/// A single permission card's receipt (permissions/record.ts): one muted line, the decision first.
export const PermissionRecordRow = memo(
  function PermissionRecordRow({ row }: RowProps) {
    const t = useT();
    const decision = row.decision;
    if (!decision) return null;
    return (
      <div className="acpmux-permission-record" data-decision={decision.kind}>
        {t(DECISION_TEXT[decision.kind], {
          action: row.permission?.title?.trim() || t("permission.required"),
          option: decision.kind === "answered" ? decision.option : "",
          mode: decision.kind === "fullAccess" ? decision.mode : "",
        })}
        {row.answeredBy && <AnsweredBy person={row.answeredBy} />}
      </div>
    );
  },
  (a, b) => a.row.id === b.row.id && a.row.version === b.row.version,
);
