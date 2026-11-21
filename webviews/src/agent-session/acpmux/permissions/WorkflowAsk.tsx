// A Claude Workflow call's permission ask, drawn as the workflow's approval card (Labs
// `workflowLabs`): the run's phases in order, then a caution that a workflow runs many agents and
// can use a lot of tokens. The answers stay Claude's own ask's (Run once, Always run, Deny), so the
// card is the real gate: the workflow starts only on an allow (PermissionCard).
import { useT } from "../i18n";
import type { AcpmuxWorkflowAsk } from "../model";

export function WorkflowAskBody({ workflow }: { workflow: AcpmuxWorkflowAsk }) {
  const t = useT();
  return (
    <div className="acpmux-permission-workflow">
      {workflow.phases.length > 0 && (
        <ol className="acpmux-permission-workflow-phases" aria-label={t("workflow.ask.phases")}>
          {workflow.phases.map((phase, index) => (
            // Two phases may share a title: the position keeps their keys apart.
            <li key={`${index}:${phase}`}>
              <span className="acpmux-permission-workflow-index" aria-hidden="true">
                {index + 1}
              </span>
              <span className="acpmux-permission-workflow-phase">{phase}</span>
            </li>
          ))}
          {workflow.morePhases !== undefined && (
            <li className="acpmux-permission-workflow-more">
              {t("workflow.ask.morePhases", { n: workflow.morePhases })}
            </li>
          )}
        </ol>
      )}
      {workflow.resume && (
        <p className="acpmux-permission-workflow-resume">{t("workflow.ask.resume", { run: workflow.resume })}</p>
      )}
      <p className="acpmux-permission-workflow-caution">{t("workflow.ask.caution")}</p>
    </div>
  );
}
