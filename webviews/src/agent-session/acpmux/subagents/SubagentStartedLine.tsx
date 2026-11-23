import { Fragment, useContext, type ReactNode } from "react";
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
import { SubagentChipPreview } from "./SubagentPreview";
import "./SubagentStartedLine.css";
import { intl } from "../../../ui/intl";

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
  const list = intl.ListFormat(language, { type: "conjunction" });
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
  const taggedNames: ReactNode[] = [];
  for (const [index, part] of list.formatToParts(names).entries()) {
    if (part.type !== "element") {
      taggedNames.push(<Fragment key={`separator-${index}`}>{part.value}</Fragment>);
      continue;
    }
    const at = agentIndex++;
    const agent = agents[at]!;
    taggedNames.push(
      <Fragment key={agent.id}>
        {at > 0 && identity(at)}
        {/* Its preview names it whole, with its state and task: a group's chips are cut to a
            letter or two (Leo, 2026-11-14: "there's no hover preview on these"). */}
        <SubagentChipPreview agent={agent} name={part.value}>
          <AgentTag
            name={part.value}
            // A name that opens the sentence ("{name} started working") starts its words on the rows'
            // text column, its chip's inset hanging into the gap after the icon (SubagentStartedLine.css).
            className={at === 0 && !before ? "cv-subagent-started__lead" : undefined}
            ariaLabel={t("subagents.open", { name: part.value })}
            onClick={open && (() => open(agent.id))}
          />
        </SubagentChipPreview>
      </Fragment>,
    );
  }
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
