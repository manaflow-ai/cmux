import { Fragment, useContext, useState, type ReactNode } from "react";
import { experimentArm } from "../../../experiments/experiment";
import type { AcpmuxRow } from "../model";
import { usePaneLanguage, useT } from "../i18n";
import { AgentTag } from "../conversation/AgentTag";
import { TranscriptActivityRow } from "../conversation/TranscriptActivityRow";
import { Tooltip } from "../../../ui/Tooltip";
import { AgentIdentity } from "./AgentIdentity";
import { agentTone } from "./agentTones";
import { foreignHarness, SUBAGENT_FALLBACK } from "./agentIdentityModel";
import { useSenderIconLook } from "./senderIconLook";
import { SubagentHarnessContext, SubagentNavContext, SubagentPaneContext, useNow } from "./subagentGroupModel";
import { groupLabel } from "./SubagentGroup";
import { subagentTaskLabel } from "./subsessions";
import { SubagentChipPreview } from "./SubagentPreview";
import { STARTED_CROWD_FROM, startedLineCrowd } from "./startedLineCrowd.experiment";
import "./SubagentStartedLine.css";
import { intl } from "../../../ui/intl";

/// A turn's "started working" line. What it says is decided before it draws (runningTray.ts
/// `startedLineModel`): the first `row.startedNamed` subagents by name, the rest as one "+N more"
/// whose hover card lists them, on one line that never runs past its width
/// (SubagentStartedLine.css).
export function SubagentStartedLine({ row }: { row: AcpmuxRow }) {
  const t = useT();
  const language = usePaneLanguage();
  const nav = useContext(SubagentNavContext);
  const pane = useContext(SubagentPaneContext);
  const harness = useContext(SubagentHarnessContext);
  const { badge } = useSenderIconLook();
  const [crowdArm] = useState(() => experimentArm(startedLineCrowd));
  const agents = row.subagents ?? [];
  const paused = agents.some((agent) => agent.capacityWait);
  const now = useNow(paused);
  if (!agents.length) return null;
  const shownCount = Math.max(1, Math.min(agents.length, row.startedNamed ?? agents.length));
  const shown = agents.slice(0, shownCount);
  const rest = agents.slice(shownCount);
  const open = pane ?? nav;
  const allNames = agents.map((agent) => subagentTaskLabel(t, agent));
  const names = allNames.slice(0, shown.length);
  const restNames = allNames.slice(shown.length);
  const more = rest.length ? t("tools.more", { n: rest.length }) : undefined;
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
  if (paused) {
    const label = groupLabel(t, language, agents, now);
    return (
      <div className="cv-tools">
        <TranscriptActivityRow
          icon={identity(0)}
          className="cv-subagent-started"
          ariaLabel={label}
          chevron={false}
          before={label}
        />
      </div>
    );
  }
  // Three or more at once (startedLineCrowd.experiment.ts; Leo, 2026-11-22: "this is so fucking
  // awkward as ui"): seven chips on one line were a letter or two each, so the crowd reads as a count.
  if (agents.length >= STARTED_CROWD_FROM && crowdArm !== "chips") {
    const sentence = t("subagents.startedLine", { name: list.format(allNames) });
    // Each icon names its subagent under the pointer and opens it, as the chips did.
    const face = (index: number) => {
      const agent = agents[index]!;
      return (
        <SubagentChipPreview key={agent.id} agent={agent} name={allNames[index]}>
          <button
            type="button"
            className="cv-subagent-started__face"
            aria-label={t("subagents.open", { name: allNames[index]! })}
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
                <SubagentChipPreview agent={agents[0]!} name={allNames[0]}>
                  <AgentTag
                    name={allNames[0]!}
                    className={!crowdBefore ? "cv-subagent-started__lead" : undefined}
                    ariaLabel={t("subagents.open", { name: allNames[0]! })}
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
  const parts = list.formatToParts(more ? [...names, more] : names);
  for (const [index, part] of parts.entries()) {
    if (part.type !== "element") {
      taggedNames.push(<Fragment key={`separator-${index}`}>{part.value}</Fragment>);
      continue;
    }
    const at = agentIndex++;
    if (at >= shown.length) {
      // The rest, counted: its card names each of them whole.
      taggedNames.push(
        // tooltip-allow: the count stands for subagents the line does not name; its card names them
        <Tooltip key="more" label={restNames.join("\n")} side="top">
          {/* oxlint-disable-next-line jsx-a11y/no-noninteractive-tabindex -- the count's card of names is keyboard-focusable without an action */}
          <span className="cv-subagent-started__more" tabIndex={0} data-testid="subagent-started-more">
            {part.value}
          </span>
        </Tooltip>,
      );
      continue;
    }
    const agent = agents[at]!;
    taggedNames.push(
      <Fragment key={agent.id}>
        {at > 0 && identity(at)}
        {/* Its preview names it whole, with its state and task (Leo, 2026-11-14: "there's no hover
            preview on these"). */}
        <SubagentChipPreview agent={agent} name={part.value}>
          <AgentTag
            name={part.value}
            // A name that opens the sentence ("{name} started working") starts its words on the rows'
            // text column, its chip's inset hanging into the gap after the icon (SubagentStartedLine.css).
            className={
              at === 0 && !before ? "cv-subagent-started__name cv-subagent-started__lead" : "cv-subagent-started__name"
            }
            ariaLabel={t("subagents.open", { name: part.value })}
            // Its name again for the chip's width floor (SubagentStartedLine.css `data-name`).
            attributes={{ "data-at": String(at), "data-name": part.value }}
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
        ariaLabel={t("subagents.startedLine", { name: list.format([...names, ...restNames]) })}
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
