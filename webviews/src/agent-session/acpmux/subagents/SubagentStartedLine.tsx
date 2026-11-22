// Subagents that started: one line in the transcript. A group used to name every subagent on one
// line, each chip cut to fit, so seven read "✧ M… , ✧ iO… , ✧ i… , … and ✧ Li… started working"
// (Leo, 2026-11-22: "this is so fucking awkward as ui. unilaterally, literally anything else would be
// a motherfucking improvement"). Now a name is never cut to fit a list (startedLine.experiment.ts,
// gallery `agent-pane.subagent-started-line`): one or two read whole in the sentence, wrapping if
// they must; three or more are their icons and a count, "7 subagents started working", that opens to
// one line per subagent, each name whole. A name wider than the whole row ends in an ellipsis, and its
// hover card names it in full (SubagentPreview.tsx).
import { Fragment, useContext, useState, type ReactNode } from "react";
import type { AcpmuxRow } from "../model";
import { usePaneLanguage, useT } from "../i18n";
import { AgentTag } from "../conversation/AgentTag";
import { TranscriptActivityRow } from "../conversation/TranscriptActivityRow";
import { experimentArm } from "../../../experiments/experiment";
import { AgentIdentity } from "./AgentIdentity";
import { agentTone } from "./agentTones";
import { foreignHarness, SUBAGENT_FALLBACK } from "./agentIdentityModel";
import { useSenderIconLook } from "./senderIconLook";
import { SubagentHarnessContext, SubagentNavContext, SubagentPaneContext } from "./subagentGroupModel";
import type { Subagent } from "./subagentFold";
import { subagentTaskLabel } from "./subsessions";
import { SubagentChipPreview } from "./SubagentPreview";
import { startedLineLook } from "./startedLine.experiment";
import "./SubagentStartedLine.css";
import { intl } from "../../../ui/intl";

/// From this many subagents the `count` look draws a count that opens, not the names.
export const STARTED_COUNT_FROM = 3;
/// The most icons the count's stack draws; the count says how many there are.
const STACK_ICONS = 5;

export function SubagentStartedLine({ row }: { row: AcpmuxRow }) {
  const [look] = useState(() => experimentArm(startedLineLook));
  const [open, setOpen] = useState(false);
  const t = useT();
  const language = usePaneLanguage();
  const nav = useContext(SubagentNavContext);
  const pane = useContext(SubagentPaneContext);
  const harness = useContext(SubagentHarnessContext);
  const { badge } = useSenderIconLook();
  const agents = row.subagents ?? [];
  if (!agents.length) return null;
  const openAgent = pane ?? nav;
  const [before, after] = t("subagents.startedLine", { name: "\u0000" }).split("\u0000");
  const identity = (agent: Subagent) => (
    <AgentIdentity
      harness={foreignHarness(agent.harness, harness, badge)}
      tone={agentTone(agent.id)}
      size={14}
      fallback={SUBAGENT_FALLBACK}
    />
  );
  const chip = (agent: Subagent, name: string, lead: boolean) => (
    // Its preview names it whole, with its state and task (Leo, 2026-11-14: "there's no hover preview
    // on these").
    <SubagentChipPreview agent={agent} name={name}>
      <AgentTag
        name={name}
        // A name that opens the sentence ("{name} started working") starts its words on the rows'
        // text column, its chip's inset hanging into the gap after the icon (SubagentStartedLine.css).
        className={lead && !before ? "cv-subagent-started__lead" : undefined}
        ariaLabel={t("subagents.open", { name })}
        onClick={openAgent && (() => openAgent(agent.id))}
      />
    </SubagentChipPreview>
  );
  const list = intl.ListFormat(language, { type: "conjunction" });
  const afterWords = after ? <span className="cv-subagent-started__after">{after}</span> : undefined;

  /// The sentence naming `group`, every name whole: each subagent's icon, chip and the list's words
  /// after it ("," or ", and") are one unit, so a line breaks between names, never inside one, and a
  /// comma never stands apart from its name.
  const sentence = (group: readonly Subagent[], className: string) => {
    const names = group.map((agent) => subagentTaskLabel(t, agent));
    const units: { agent: Subagent; name: string; tail: string }[] = [];
    let lead = before ?? "";
    for (const part of list.formatToParts(names)) {
      if (part.type === "element") units.push({ agent: group[units.length]!, name: part.value, tail: "" });
      else if (units.length) units[units.length - 1]!.tail += part.value;
      else lead += part.value;
    }
    return (
      <TranscriptActivityRow
        icon={identity(group[0]!)}
        className={`cv-subagent-started ${className}`}
        ariaLabel={t("subagents.startedLine", { name: list.format(names) })}
        chevron={false}
        before={
          <>
            {lead.trim() && <span className="cv-subagent-started__before">{lead.trim()}</span>}
            {units.map(({ agent, name, tail }, index) => (
              <span key={agent.id} className="cv-subagent-started__unit">
                {index > 0 && <span className="cv-subagent-started__icon">{identity(agent)}</span>}
                {chip(agent, name, index === 0)}
                {tail.trim() && <span className="cv-subagent-started__sep">{tail.trim()}</span>}
              </span>
            ))}
          </>
        }
        after={afterWords}
      />
    );
  };

  /// The look it replaced, kept as the experiment's `before` arm: every name on one line, the chips
  /// cut to fit.
  const beforeLine = (): ReactNode => {
    const names = agents.map((agent) => subagentTaskLabel(t, agent));
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
          {at > 0 && identity(agent)}
          {chip(agent, part.value, at === 0)}
        </Fragment>,
      );
    }
    return (
      <TranscriptActivityRow
        icon={identity(agents[0]!)}
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
    );
  };

  if (look === "before") return <div className="cv-tools">{beforeLine()}</div>;
  if (look === "lines")
    return (
      <div className="cv-tools">
        {agents.map((agent) => (
          <Fragment key={agent.id}>{sentence([agent], "is-whole")}</Fragment>
        ))}
      </div>
    );
  if (look === "wrap" || agents.length < STARTED_COUNT_FROM)
    return <div className="cv-tools">{sentence(agents, "is-whole")}</div>;

  // The count: its icons, "7 subagents started working", and a chevron that opens the names.
  const count = t("subagents.count", { n: agents.length });
  const shown = agents.slice(0, STACK_ICONS);
  return (
    <div className="cv-tools cv-subagent-started-group" data-open={open || undefined}>
      <TranscriptActivityRow
        icon={identity(agents[0]!)}
        className="cv-subagent-started is-count"
        ariaLabel={t("subagents.startedLine", { name: count })}
        expanded={open}
        attributes={{ "aria-expanded": open ? "true" : "false" }}
        onClick={() => setOpen((was) => !was)}
        before={
          <>
            {before?.trim() && <span className="cv-subagent-started__before">{before.trim()}</span>}
            <span className="cv-subagent-started__count">{count}</span>
          </>
        }
        after={afterWords}
      >
        {shown.length > 1 && (
          <span className="cv-subagent-started__stack" aria-hidden="true">
            {shown.slice(1).map((agent) => (
              <span key={agent.id} className="cv-subagent-started__face">
                {identity(agent)}
              </span>
            ))}
          </span>
        )}
      </TranscriptActivityRow>
      {open && (
        <div className="cv-subagent-started__names">
          {agents.map((agent) => (
            <div key={agent.id} className="cv-tool cv-subagent-started__item">
              <span className="cv-tool__icon cv-agent-activity__icon">{identity(agent)}</span>
              <span className="cv-agent-activity__sentence">{chip(agent, subagentTaskLabel(t, agent), false)}</span>
            </div>
          ))}
        </div>
      )}
    </div>
  );
}
