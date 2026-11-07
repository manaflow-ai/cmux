// One leader row answers who owns the work, which machine holds it, and who needs the person.
// The underlying 'lane.reportsTo' relationship remains same-machine (leads.ts/lane_reports.rs).
import { leaders } from "../leads";
import { sessionMark } from "../sessionList";
import type { ActiveChat } from "./AllChatsList";
import type { NewTabTranslate } from "./strings";

/** The leader and its direct reports need attention if acpmux explicitly marks input pending. */
export function leaderCards(sessions: Parameters<typeof leaders>[0], nt: NewTabTranslate): ActiveChat[] {
  return leaders(sessions).map(({ entry, reports }) => {
    const state: ActiveChat["state"] =
      entry.indicator === "failed" ? "failed" : (sessionMark(entry, false) ?? "idle");
    const needsInput =
      (state === "input" ? 1 : 0) + reports.filter((report) => sessionMark(report, false) === "input").length;
    const location = entry.peer ?? entry.host;
    return {
      id: entry.sessionId,
      ...(entry.peer ? { peer: entry.peer } : {}),
      title: entry.displayTitle ?? entry.name ?? entry.sessionId,
      ...(entry.harness ? { harness: entry.harness } : {}),
      ...(location ? { location } : {}),
      ...(needsInput ? { needsInput } : {}),
      state,
      label: nt("leads.reports", { count: String(reports.length) }),
    };
  });
}
