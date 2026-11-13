import { Fragment, useContext } from "react";
import type { AcpmuxRow } from "../model";
import { usePaneLanguage, useT } from "../i18n";
import { AgentTag } from "../conversation/AgentTag";
import { TranscriptActivityRow } from "../conversation/TranscriptActivityRow";
import { AgentIdentity } from "./AgentIdentity";
import { agentTone } from "./agentTones";
import { foreignHarness, SUBAGENT_FALLBACK } from "./agentIdentityModel";
import { useSenderIconLook } from "./senderIconLook";
import { SubagentHarnessContext, SubagentNavContext, SubagentPaneContext } from "./subagentGroupModel";
import { subagentTaskLabel } from "./subsessions";

export function SubagentStartedLine({ row }: { row: AcpmuxRow }) {
  const t = useT();
  const language = usePaneLanguage();
  const nav = useContext(SubagentNavContext);
  const pane = useContext(SubagentPaneContext);
  const harness = useContext(SubagentHarnessContext);
  const { badge } = useSenderIconLook();
  const agents = row.subagents ?? [];
  if (!agents.length) return null;
  const open = pane ?? nav;
  const names = agents.map((agent) => subagentTaskLabel(t, agent));
  const list = new Intl.ListFormat(language, { type: "conjunction" });
  const [before, after] = t("subagents.startedLine", { name: "\u0000" }).split("\u0000");
  const identity = (index: number) => (
    <AgentIdentity
      harness={foreignHarness(agents[index]!.harness, harness, badge)}
      tone={agentTone(agents[index]!.id)}
      size={14}
      fallback={SUBAGENT_FALLBACK}
    />
  );
  let agentIndex = 0;
  const taggedNames = list.formatToParts(names).map((part, index) => {
    if (part.type !== "element") return <Fragment key={`separator-${index}`}>{part.value}</Fragment>;
    const at = agentIndex++;
    const agent = agents[at]!;
    return (
      <Fragment key={agent.id}>
        {at > 0 && identity(at)}
        <AgentTag
          name={part.value}
          ariaLabel={t("subagents.open", { name: part.value })}
          onClick={open && (() => open(agent.id))}
        />
      </Fragment>
    );
  });
  return (
    <div className="cv-tools">
      <TranscriptActivityRow
        icon={identity(0)}
        className="cv-subagent-started"
        ariaLabel={t("subagents.startedLine", { name: list.format(names) })}
        chevron={false}
        before={
          <>
            {before}
            {taggedNames}
          </>
        }
        after={after || undefined}
      />
    </div>
  );
}
