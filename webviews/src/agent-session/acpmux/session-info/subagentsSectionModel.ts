import { type Translate } from "../i18n";
import type { StartedSession } from "../started/startedSessions";
import type { Subagent } from "../subagents/subagentFold";
import { subagentStatus, type SubagentStatus } from "../summary/subagentStatusListModel";
import { sessionStatus } from "./childSessionRowsModel";
import { countParts, countText, live, type CountPart } from "../summary/LiveCount";

/// Running lines shown before "Show more", as Claude Code desktop's panel caps its list.
export const SUBAGENTS_SHOWN = 5;
export const NO_SESSIONS: readonly StartedSession[] = [];

/// "1 waiting · 3 running · 1 queued · 40 done" (the native text) for the section's head, the started chats counted with the
/// subagents, or nothing for neither.
/// With the clock (`now`), a subagent quiet past IDLE_AFTER_MS counts as idle, as its line reads:
/// the head and the lines read one status each (Leo, 2026-11-02: "but what's going on with these?").
/// The page draws the running ones as their mark and number (`subagentCountParts`, LiveCount.tsx);
/// this text, with their word, is the App's native Session Info's meta, which draws only text.
export function subagentCounts(
  t: Translate,
  agents: readonly Subagent[],
  waiting: ReadonlySet<string>,
  sessions: readonly StartedSession[] = NO_SESSIONS,
  now?: number,
): string {
  return countText(subagentCountParts(t, agents, waiting, sessions, now));
}

/// The head's counts as parts: the running ones as their mark and number, no word (LiveCount.tsx).
export function subagentCountParts(
  t: Translate,
  agents: readonly Subagent[],
  waiting: ReadonlySet<string>,
  sessions: readonly StartedSession[] = NO_SESSIONS,
  now?: number,
): CountPart[] {
  // A chat acpmux holds for a free slot (`waitsForSlot`) is queued, as the running limit's line
  // says, never done or idle by its state.
  const queued = sessions.filter((child) => child.waitsForSlot).length;
  const count = (status: SubagentStatus) =>
    agents.filter((agent) => subagentStatus(agent, waiting, now) === status).length +
    sessions.filter((child) => !child.waitsForSlot && sessionStatus(child) === status).length;
  return countParts(
    count("waiting") > 0 && t("summary.subagents.waiting", { n: count("waiting") }),
    live(count("running"), t("summary.subagents.running", { n: count("running") })),
    queued > 0 && t("sessionInfo.subagents.limit.queued", { n: queued }),
    count("idle") > 0 && t("summary.subagents.idle", { n: count("idle") }),
    count("failed") > 0 && t("summary.subagents.failed", { n: count("failed") }),
    count("stopped") > 0 && t("summary.subagents.stopped", { n: count("stopped") }),
    count("done") > 0 && t("summary.subagents.done", { n: count("done") }),
  );
}
