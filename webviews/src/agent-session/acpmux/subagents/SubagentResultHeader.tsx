// The compact result head shown when a completed subagent opens. It keeps the final report in view
// above the full transcript, matching ChatGPT's result-first drill-in without hiding any rows.
import { useMemo } from "react";
import { CopyButton } from "../conversation/CopyButton";
import { Markdown } from "../conversation/Markdown";
import { formatDuration } from "../conversation/turns";
import { useT } from "../i18n";
import type { Subagent } from "./subagentFold";
import { STATE_LABEL, elapsed, running, useNow } from "./SubagentGroup";

export function SubagentResultHeader({ agent }: { agent: Subagent }) {
  const t = useT();
  const live = running(agent);
  const now = useNow(live);
  const report = agent.result?.trim() || agent.lastMessage?.trim();
  const state = t(STATE_LABEL[agent.state as keyof typeof STATE_LABEL] ?? STATE_LABEL.completed);
  const duration = formatDuration(elapsed(agent, live ? now : (agent.endedAt ?? agent.startedAt)));
  const copy = useMemo(
    () => agent.result?.trim() || agent.lastMessage?.trim() || "",
    [agent.result, agent.lastMessage],
  );
  return (
    <section className="cv-subagent-result" data-state={agent.state}>
      <div className="cv-subagent-result__meta">
        <span className="cv-subagent-result__state">{state}</span>
        <span aria-hidden="true">·</span>
        <span>{duration}</span>
        {copy && <CopyButton text={copy} label={t("turn.copy")} className="cv-iconbtn cv-iconbtn--compact" />}
      </div>
      {report ? (
        <div className="cv-subagent-result__report">
          <Markdown>{report}</Markdown>
        </div>
      ) : (
        <p className="cv-subagent-result__empty">{state}</p>
      )}
    </section>
  );
}
