// The page's mark `an adopt event carried a state, and this page took it` (pageWake.ts `applyWake`).
//
// The host keeps its copy of a chat's held state until a paint report of the page says `appliedWake`
// (AgentPaneModel `pendingWake`). While it keeps it, its copy goes before the page's own answer when the
// page is released and when the app quits. So the mark must get to the host.

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
  return {
    took() {
      set = true;
    },
    report() {
      const applied = set;
      set = false;
      return { applied, reached() {} };
    },
  };
}
