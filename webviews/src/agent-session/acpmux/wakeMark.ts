// The page's mark `an adopt event carried a state, and this page took it` (pageWake.ts `applyWake`).
//
// The host keeps its copy of a chat's held state until a paint report of the page says `appliedWake`
// (AgentPaneModel `pendingWake`). While it keeps it, its copy goes before the page's own answer when the
// page is released and when the app quits. So the mark must get to the host.
//
// The rule (decision 2026-11-16): the mark stays until the call of a report that carried it resolved. A
// report whose call failed leaves it for the page's next report. Before, the mark went off when the report
// was made, before its call: one lost call left the host's old copy in force for the life of the page.
//
// Limits: the page makes a paint report at its first paint after an adopt event, and one more when the
// chat's frame settles later. When each of them is lost, the mark stays and no report carries it. A call
// that never resolves and never fails clears nothing and starts nothing.

/// One paint report's part of the mark.
export type WakeReport = {
  /// The report carries the mark (`appliedWake`).
  applied: boolean;
  /// The report's call resolved: the host has it.
  reached: () => void;
};

export type WakeMark = {
  /// An adopt event's state was applied to this page.
  took(): void;
  /// The mark for one paint report, read when the report is made.
  report(): WakeReport;
};

export function wakeMark(): WakeMark {
  let set = false;
  // The adopt events with a state, counted: a report made before the newest one says nothing of its state.
  let adopts = 0;
  return {
    took() {
      set = true;
      adopts += 1;
    },
    report() {
      const applied = set;
      const at = adopts;
      return {
        applied,
        reached() {
          if (applied && at === adopts) set = false;
        },
      };
    },
  };
}
