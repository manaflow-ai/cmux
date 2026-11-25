// What waits on the agent's side and never on the person's: the chat's held message surge
// (conversation/surgeHold.ts) and acpmux's own prompts in the queue (a surge digest, a subagent's
// resume, a cut turn's continuation: queuedMessages.ts `systemQueue`). Leo, 2026-11-24, of the held
// bar over the composer: "this, it's not aligned. it's also not useful to show this to the user";
// and of acpmux's queued prompts: "why would a user steer or whatever on these? they should be
// separated out from the user visible steer ui area. maybe not even interactable?" So neither draws
// in the composer's stack: both are plain rows at the foot of Session Info's Background tasks, with
// no action, the web panel's (SessionInfo.tsx) and the App's (native/tasks.ts) from this one list.
import type { AcpmuxSnapshot } from "../model";
import type { Translate } from "../i18n";
import { surgeShows, type SurgeHold } from "../conversation/surgeHold";
import { systemQueue } from "../conversation/queuedMessages";
import { shownText } from "../composerQueueModel";

export type AgentSideRow = {
  id: string;
  kind: "held" | "queued";
  title: string;
  /// Dimmer text after the title (how many need the agent; who queued it).
  detail?: string;
  /// Right-aligned: the held count.
  trailing?: string;
  /// The whole prompt, for a tooltip.
  help?: string;
};

/// The pack icon (web) and SF Symbol (native) per kind.
export const AGENT_SIDE_ICONS: Record<AgentSideRow["kind"], { web: string; native: string }> = {
  held: { web: "inbox", native: "tray.full" },
  queued: { web: "history", native: "arrow.uturn.forward" },
};

/// The rows, held surge first, then acpmux's queued prompts in the queue's order.
export function agentSideRows(
  t: Translate,
  surge: SurgeHold | undefined,
  queue: AcpmuxSnapshot["queue"],
): AgentSideRow[] {
  const rows: AgentSideRow[] = [];
  if (surgeShows(surge))
    rows.push({
      id: "held",
      kind: "held",
      title: t("surge.title"),
      ...(surge.needYou > 0 ? { detail: t("surge.needYou", { n: surge.needYou }) } : {}),
      trailing: t("surge.held", { n: surge.held }),
    });
  for (const entry of systemQueue(queue)) {
    const text = shownText(entry, t);
    rows.push({
      id: `queued:${entry.id}`,
      kind: "queued",
      title: text.split("\n", 1)[0] ?? "",
      detail: t("composer.queueSystem"),
      help: text,
    });
  }
  return rows;
}

const NO_ROWS: AgentSideRow[] = [];
let last:
  | { t: Translate; surge: SurgeHold | undefined; queue: AcpmuxSnapshot["queue"]; rows: AgentSideRow[] }
  | undefined;

/// `agentSideRows` that hands back the same array while the surge and the queue are the same, so a
/// snapshot that moves neither redraws no panel (samePanelProps.ts compares by reference).
export function agentSideRowsOf(t: Translate, surge: SurgeHold | undefined, queue: AcpmuxSnapshot["queue"]) {
  if (last && last.t === t && last.surge === surge && last.queue === queue) return last.rows;
  const rows = agentSideRows(t, surge, queue);
  last = { t, surge, queue, rows: rows.length === 0 ? NO_ROWS : rows };
  return last.rows;
}
