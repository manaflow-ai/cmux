// "Approved" at a tool row's edge (CommandRow.tsx, ToolRow.tsx): the person approved this call's
// permission ask, so the approval reads on the call it approved, never as a loose transcript line
// holding the raw command (Leo, 2026-11-02, on "Approved: cd /tmp; for i in 1 2 3; do gh issue
// create … (Bypass permissions)": "but what's going on with these?"). An approval the chat's
// Bypass permissions or Full access gave on its own draws nothing (direct.ts `recordFullAccess`).
import { useT } from "../i18n";

export function ApprovedMark() {
  const t = useT();
  return (
    <span className="cv-command__approved" data-find-skip>
      {t("tools.approved")}
    </span>
  );
}
