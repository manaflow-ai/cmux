import { useId, useState } from "react";
import { Markdown } from "./conversation/Markdown";
import { ChevronDown, Close } from "./conversation/icons";
import { useT } from "./i18n";
import { approvedPlanClosed, approvedPlanKey, rememberApprovedPlanClosed, type ApprovedPlan } from "./approvedPlan";
import "./ApprovedPlanBand.css";

/// The approved plan, a row of the composer hat beside the goal: folded to its heading by default,
/// open to the plan's Markdown, closed with × until a new plan is approved. Leo's row: "plan pane
/// that stays during the build, editable plan sent back".
export function ApprovedPlanBand({
  chat,
  plan,
  initiallyOpen = false,
}: {
  chat: string;
  plan: ApprovedPlan;
  initiallyOpen?: boolean;
}) {
  const t = useT();
  const bodyId = useId();
  const key = approvedPlanKey(chat, plan);
  const [open, setOpen] = useState(initiallyOpen);
  const [closedKey, setClosedKey] = useState<string | undefined>(() => (approvedPlanClosed(key) ? key : undefined));
  if (closedKey === key || approvedPlanClosed(key)) return null;
  const firstLine = plan.markdown.split("\n").find((line) => line.trim() !== "") ?? "";
  const title = firstLine.replace(/^#+\s*/, "").trim();
  return (
    <section
      className="ui-glass ui-glass-floats acpmux-stack-material acpmux-approved-plan"
      data-open={open ? "true" : undefined}
      aria-label={t("approvedPlan.label")}
    >
      <div className="acpmux-approved-plan-head">
        <button
          type="button"
          className="acpmux-approved-plan-toggle"
          aria-expanded={open}
          aria-controls={bodyId}
          aria-label={open ? t("approvedPlan.hide") : t("approvedPlan.show")}
          onClick={() => setOpen((value) => !value)}
          onKeyDown={(event) => {
            if (event.key !== "Escape" || !open) return;
            event.stopPropagation();
            setOpen(false);
          }}
        >
          <span className="acpmux-approved-plan-label">{t("approvedPlan.label")}</span>
          {plan.edited && <span className="acpmux-approved-plan-tag">{t("approvedPlan.edited")}</span>}
          <span className="acpmux-approved-plan-title">{title}</span>
          <ChevronDown size={14} />
        </button>
        <button
          type="button"
          className="acpmux-approved-plan-close"
          aria-label={t("approvedPlan.close")}
          title={t("approvedPlan.close")}
          onClick={() => {
            rememberApprovedPlanClosed(key);
            setClosedKey(key);
          }}
        >
          <Close size={14} />
        </button>
      </div>
      {open && (
        <div id={bodyId} className="acpmux-approved-plan-body acpmux-permission-plan">
          <Markdown plainCode>{plan.markdown}</Markdown>
        </div>
      )}
    </section>
  );
}
