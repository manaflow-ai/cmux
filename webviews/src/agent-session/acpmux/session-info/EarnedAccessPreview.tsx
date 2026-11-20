import { useState } from "react";
import { experimentArm } from "../../../experiments/experiment";
import { useT, type StringKey } from "../i18n";
import type { Enforcement } from "../handoff/protocol";
import { earnedAccessPreview } from "./earnedAccess.experiment";
import { useEarnedAccessLabs } from "./earnedAccessLabs";
import { SessionInfoFold } from "./SessionInfoSection";

const labels: Readonly<Record<string, StringKey>> = {
  readOnly: "earnedAccess.readOnly",
  reads: "policy.approveReads",
  edits: "policy.approveEdits",
  full: "picker.approvesAll",
  ask: "policy.ask",
  denyAll: "policy.denyAll",
};

/** A preview of the design, not a permission control. Old daemons omit it altogether. */
export function EarnedAccessPreview({ enforcement }: { enforcement?: Enforcement }) {
  const t = useT();
  const labs = useEarnedAccessLabs();
  const [open, setOpen] = useState(false);
  const preview = enforcement?.accessPreview;
  if ((!labs && experimentArm(earnedAccessPreview) !== "on") || !preview || preview.eligibility !== "unavailable")
    return null;
  return (
    <li data-earned-access-preview>
      <SessionInfoFold open={open} onToggle={() => setOpen(!open)}>
        <span className="acpmux-session-info-row__name">{t("earnedAccess.title")}</span>
        <span className="acpmux-session-info-row__end">
          {t(Object.hasOwn(labels, preview.current) ? labels[preview.current] : "earnedAccess.unknown")}
        </span>
      </SessionInfoFold>
      {open && (
        <div className="acpmux-session-info-note acpmux-session-info-note--label">
          <p>{t("earnedAccess.unavailable")}</p>
          <p>{t("earnedAccess.requirements")}</p>
          <p>{t("earnedAccess.unchanged")}</p>
        </div>
      )}
    </li>
  );
}
