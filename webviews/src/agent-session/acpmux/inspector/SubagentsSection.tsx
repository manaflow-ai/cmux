// The Inspector's Subagents (after ChatGPT's pinned summary): one row of the chat's subagents'
// avatars, the running ones first and breathing softly, with the live counts in the section's
// head ("3 running · 40 done"). A click on the row opens the list below it: Active, then Done,
// each subagent as the transcript draws it (SubagentsTab.tsx); a row shows that subagent.
import { useState } from "react";
import { useT, type Translate } from "../i18n";
import { Avatar, running } from "../subagents/SubagentGroup";
import type { Subagent } from "../subagents/subagentFold";
import { subagentStatus, type SubagentStatus } from "../summary/SubagentStatusList";
import { SubagentsTab } from "../summary/SubagentsTab";

/// Avatars drawn before "+N"; the row is one line at the Inspector's narrowest.
const SHOWN = 8;

/// "1 waiting · 3 running · 40 done" for the section's head, or nothing for no subagents.
export function subagentCounts(t: Translate, agents: readonly Subagent[], waiting: ReadonlySet<string>): string {
  const count = (status: SubagentStatus) => agents.filter((agent) => subagentStatus(agent, waiting) === status).length;
  return [
    count("waiting") > 0 && t("summary.subagents.waiting", { n: count("waiting") }),
    count("running") > 0 && t("summary.subagents.running", { n: count("running") }),
    count("failed") > 0 && t("summary.subagents.failed", { n: count("failed") }),
    count("stopped") > 0 && t("summary.subagents.stopped", { n: count("stopped") }),
    count("done") > 0 && t("summary.subagents.done", { n: count("done") }),
  ]
    .filter(Boolean)
    .join(" · ");
}

export function SubagentsSection({
  agents,
  waiting,
  onOpen,
}: {
  agents: readonly Subagent[];
  waiting: ReadonlySet<string>;
  onOpen: (id: string) => void;
}) {
  const t = useT();
  const [listed, setListed] = useState(false);
  // Running ones lead the row; then the newest.
  const order = [...agents].sort((a, b) => Number(running(b)) - Number(running(a)) || b.startedAt - a.startedAt);
  const label = listed ? t("chatInspector.subagents.hide") : t("chatInspector.subagents.show", { n: agents.length });
  return (
    <div className="acpmux-inspector-subagents">
      <button
        type="button"
        className="acpmux-inspector-avatars"
        aria-expanded={listed}
        aria-label={label}
        onClick={() => setListed(!listed)}
      >
        <span className="acpmux-inspector-avatars__stack" aria-hidden="true">
          {order.slice(0, SHOWN).map((agent) => (
            <Avatar key={agent.id} agent={agent} dot />
          ))}
        </span>
        {agents.length > SHOWN && (
          <span className="acpmux-inspector-avatars__more" aria-hidden="true">
            +{agents.length - SHOWN}
          </span>
        )}
      </button>
      {listed && (
        <div className="acpmux-inspector-scroll acpmux-inspector-subagents__list">
          <SubagentsTab agents={agents} waiting={waiting} onOpen={onOpen} />
        </div>
      )}
    </div>
  );
}
