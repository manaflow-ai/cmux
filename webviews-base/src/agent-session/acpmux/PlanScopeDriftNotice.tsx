import { translate, useT } from "./i18n";
import { Notice as UiNotice } from "../../ui/Notice";
import { useNoticeTurn } from "./noticeSlotModel";
import {
  dismissPlanScopeDrift,
  keepPlanScopeArea,
  usePlanScopeDrift,
  type PlanScopeDrift,
} from "./planScopeDriftStore";

type DriftAction = "keepGoing" | "replan" | "stop";

type PlanScopeDriftAction = {
  action: DriftAction;
  sessionId: string;
  path: string;
  area: string;
};

function resolveDrift(action: DriftAction, drift: PlanScopeDrift, onStop?: () => void): void {
  // Let the connected pane own the side effect when it exposes the action. This keeps the
  // notice testable and gives native hosts one stable action contract, while the local fallback
  // keeps a gallery or an older host functional.
  const delegated = window.cmuxAcpmuxActions?.["chat.planScopeDrift"];
  if (delegated) {
    const params: PlanScopeDriftAction = {
      action,
      sessionId: drift.sessionId,
      path: drift.path,
      area: drift.area,
    };
    void delegated(params);
    return;
  }
  if (action === "keepGoing") {
    keepPlanScopeArea(drift.sessionId, drift.area);
    return;
  }
  if (action === "stop") {
    dismissPlanScopeDrift(drift.sessionId);
    onStop?.();
    if (!onStop) void window.cmuxAcpmuxActions?.["chat.cancel"]?.({});
    return;
  }
  dismissPlanScopeDrift(drift.sessionId);
  void window.cmuxAcpmuxActions?.["chat.send"]?.({
    text: translate("planScopeDrift.replanPrompt", { path: drift.path }),
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
          onSelect: () => resolveDrift("stop", drift, onStop),
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
