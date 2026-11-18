// What a Claude Workflow call's permission ask shows while the Labs workflow surfaces are on
// (`workflowLabs` with Settings > Advanced > Labs, workflowCardModel `workflowLabs`; WorkflowAsk.tsx draws it).
import { useSyncExternalStore } from "react";
import type { Translate } from "../i18n";
import type { AcpmuxPermission, AcpmuxWorkflowAsk } from "../model";
import { listeners, workflowLabs } from "../summary/workflowCardModel";

const subscribe = (listener: () => void) => {
  listeners.add(listener);
  return () => void listeners.delete(listener);
};
const current = () => workflowLabs;

/// The ask's workflow while the Labs surface is on; undefined otherwise, so the ask draws as any tool's.
export function useWorkflowAsk(permission: AcpmuxPermission): AcpmuxWorkflowAsk | undefined {
  const labs = useSyncExternalStore(subscribe, current, current);
  return labs ? permission.workflow : undefined;
}

/// The card's title: "Run workflow review-changes?", or "Run a workflow?" with no name.
export function workflowAskTitle(workflow: AcpmuxWorkflowAsk, t: Translate): string {
  return workflow.name ? t("workflow.ask.title", { name: workflow.name }) : t("workflow.ask.titleUnnamed");
}
