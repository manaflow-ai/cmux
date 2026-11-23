import { Fragment, useContext, type ReactNode, useState } from "react";
import { experimentArm } from "../../../experiments/experiment";
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
import { STARTED_CROWD_FROM, startedLineCrowd } from "./startedLineCrowd.experiment";
import "./SubagentStartedLine.css";
import { intl } from "../../../ui/intl";

/// The most names one start line spells out; the rest are counted ("+21 more"). Every name shares
/// the line's width, so a line naming them all drew two dozen chips cut to their padding: empty grey
/// pills between icons and commas (Leo, 2026-11-22, after a restart: "and more bullshit somehow
/// happened here"). Each subagent's own line and the tray still name every one.
export const STARTED_NAMES = 3;

export function SubagentStartedLine({ row }: { row: AcpmuxRow }) {
  const t = useT();
  const language = usePaneLanguage();
  const nav = useContext(SubagentNavContext);
  const pane = useContext(SubagentPaneContext);
  const harness = useContext(SubagentHarnessContext);
  const { badge } = useSenderIconLook();
  const [crowdArm] = useState(() => experimentArm(startedLineCrowd));
  const agents = row.subagents ?? [];
  if (!agents.length) return null;
  const open = pane ?? nav;
  const all = agents.map((agent) => subagentTaskLabel(t, agent));
  // Past the cap, the last element counts the rest: never a chip too narrow to read.
  const shown = all.length > STARTED_NAMES ? STARTED_NAMES - 1 : all.length;
  const rest = all.length - shown;
  const names = rest > 0 ? [...all.slice(0, shown), t("tools.more", { n: rest })] : all;
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
  // Three or more at once (startedLineCrowd.experiment.ts; Leo, 2026-11-22: "this is so fucking
  // awkward as ui"): seven chips on one line were a letter or two each, so the crowd reads as a count.
  if (agents.length >= STARTED_CROWD_FROM && crowdArm !== "chips") {
    const sentence = t("subagents.startedLine", { name: list.format(names) });
    // Each icon names its subagent under the pointer and opens it, as the chips did.
    const face = (index: number) => {
      const agent = agents[index]!;
      return (
        <SubagentChipPreview key={agent.id} agent={agent} name={names[index]}>
          <button
            type="button"
            className="cv-subagent-started__face"
            aria-label={t("subagents.open", { name: names[index]! })}
            disabled={!open}
            onClick={open && (() => open(agent.id))}
          >
            {identity(index)}
          </button>
        </SubagentChipPreview>
      );
    };
    const counted = t("subagents.startedLine", { name: t("subagents.count", { n: agents.length }) });
    const [crowdBefore, crowdAfter] =
      crowdArm === "first" ? t("subagents.startedLine", { name: "\u0000" }).split("\u0000") : [counted, undefined];
    return (
      <div className="cv-tools">
        <TranscriptActivityRow
          icon={face(0)}
          className="cv-subagent-started"
          attributes={{ "data-crowd": crowdArm }}
          ariaLabel={sentence}
          chevron={false}
          before={
            crowdArm === "first" ? (
              <>
                {crowdBefore}
                <SubagentChipPreview agent={agents[0]!} name={names[0]}>
                  <AgentTag
                    name={names[0]!}
                    className={!crowdBefore ? "cv-subagent-started__lead" : undefined}
                    ariaLabel={t("subagents.open", { name: names[0]! })}
                    onClick={open && (() => open(agents[0]!.id))}
                  />
                </SubagentChipPreview>{" "}
                <span className="cv-subagent-started__more">{t("tools.more", { n: agents.length - 1 })}</span>
              </>
            ) : (
              <>
                {crowdArm === "faces" && (
                  <span className="cv-subagent-started__faces">
                    {agents.slice(1).map((_, index) => face(index + 1))}
                  </span>
                )}
                {crowdBefore}
              </>
            )
          }
          after={crowdAfter || undefined}
        />
      </div>
    );
  }
  let agentIndex = 0;
  const taggedNames: ReactNode[] = [];
  for (const [index, part] of list.formatToParts(names).entries()) {
    if (part.type !== "element") {
      taggedNames.push(<Fragment key={`separator-${index}`}>{part.value}</Fragment>);
      continue;
    }
    const at = agentIndex++;
    if (at >= shown) {
      taggedNames.push(
        <span key="more" className="cv-subagent-started__more">
          {part.value}
        </span>,
      );
      continue;
    }
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
        ariaLabel={t("subagents.startedLine", { name: list.format(all) })}
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
