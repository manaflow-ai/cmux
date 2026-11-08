import { useT } from "./i18n";
import { Notice as UiNotice } from "../../ui/Notice";
import { useNoticeTurn } from "./noticeSlotModel";
import {
  dismissPlanScopeDrift,
  keepPlanScopeArea,
  usePlanScopeDrift,
  type PlanScopeDrift,
} from "./planScopeDriftStore";

type DriftAction = "keepGoing" | "replan";

function resolveDrift(action: DriftAction, drift: PlanScopeDrift): void {
  if (action === "keepGoing") {
    keepPlanScopeArea(drift.sessionId, drift.area);
    return;
  }
  dismissPlanScopeDrift(drift.sessionId);
  void window.cmuxAcpmuxActions?.["chat.send"]?.({
    text: `Replan before editing ${drift.path}: update the approved plan to include this area, then continue.`,
    steer: true,
  });
}

export function PlanScopeDriftCard({ drift, onStop }: { drift: PlanScopeDrift; onStop?: () => void }) {
  const t = useT();
  return (
    <UiNotice
      id="plan-scope-drift"
      kind="warning"
      placement="banner"
      title={t("planScopeDrift.title", { path: drift.path })}
      actions={[
        {
          id: "keep-going",
          label: t("planScopeDrift.keepGoing"),
          primary: true,
          onSelect: () => resolveDrift("keepGoing", drift),
        },
        {
          id: "replan",
          label: t("planScopeDrift.replan"),
          onSelect: () => resolveDrift("replan", drift),
        },
        {
          id: "stop",
          label: t("planScopeDrift.stop"),
          onSelect:
            onStop ??
            (() => {
              dismissPlanScopeDrift(drift.sessionId);
              void window.cmuxAcpmuxActions?.["chat.cancel"]?.({});
            }),
        },
      ]}
    />
  );
}

/** A calm, persistent warning when the approved plan no longer covers an edit area. */
export function PlanScopeDriftNotice({ sessionId }: { sessionId?: string }) {
  const drift = usePlanScopeDrift(sessionId);
  const { shown } = useNoticeTurn("plan-scope-drift", "status", Boolean(drift));
  if (!shown || !drift) return null;
  return <PlanScopeDriftCard drift={drift} />;
}
