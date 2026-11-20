import { StableLabel } from "../../../ui/StableLabel";
import { useT } from "../i18n";
import type { PullRequestOps } from "./pullRequestOps";

export function PullRequestActions({ ops }: { ops: PullRequestOps }) {
  const t = useT();
  const alternatives = [
    t("header.prFixChecks"),
    t("header.prFixingChecks"),
    t("header.prAddressComments"),
    t("header.prAddressingComments"),
  ];
  return (
    <>
      {ops.headSha && <code className="acpmux-pr-head">{ops.headSha}</code>}
      {!!ops.actions?.length && (
        <div className="acpmux-pr-actions">
          {ops.actions.map((action) => (
            <button key={action.id} type="button" disabled={!action.enabled} onClick={action.run}>
              <StableLabel label={action.label} alternatives={alternatives} />
            </button>
          ))}
        </div>
      )}
      {ops.actionMessages?.map((message, index) => (
        <output key={index} className="acpmux-pr-action-error" role="alert">
          {message}
        </output>
      ))}
    </>
  );
}
