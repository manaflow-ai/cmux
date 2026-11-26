// A tool call's row counts its commits while the page measures (perf.ts, debug.ts `renders`):
// `tool:<call id>` for each commit and `tool-mount:<call id>` for each mount. A settled call that
// draws again or mounts again on a stream update that is not its own is the flicker this counts
// (test/agent-pane-tool-row-renders.test.ts). Always on, a remount in place goes to the flicker
// detector's ring file (flickerLog.ts `remount`), so one in a real chat is on record.
import { useLayoutEffect } from "react";
import { noteMounted, noteUnmounted } from "../flickerLog";
import { acpmuxPerf } from "../perf";

export function useToolRowCount(id: string | undefined, kind?: string): void {
  useLayoutEffect(() => {
    if (acpmuxPerf.enabled) acpmuxPerf.render(`tool:${id}`);
  });
  useLayoutEffect(() => {
    if (acpmuxPerf.enabled) acpmuxPerf.render(`tool-mount:${id}`);
    if (!id) return;
    noteMounted(`tool:${id}`, "tool", kind);
    return () => noteUnmounted(`tool:${id}`);
    // The kind a call mounted with: a call that changes kind is still the same row.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [id]);
}
