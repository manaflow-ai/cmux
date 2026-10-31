import type { InspectorProcess } from "./processes";

/// Overlay process updates received after listProcesses was requested. The daemon's
/// snapshot owns the list order, and each updated existing row keeps its original slot.
/// New process IDs append in first-arrival order; a later update to the same ID wins.
///
/// The caller already validated these records against the target session. One sweep of
/// the snapshot plus one sweep of the pending updates replaces an O(rows * updates) replay.
export function replayProcessUpdates(
  listed: readonly InspectorProcess[],
  pending: ReadonlyMap<string, InspectorProcess>,
): readonly InspectorProcess[] {
  if (pending.size === 0) return listed;
  const seen = new Set<string>();
  const merged = listed.map((process) => {
    // Keep the behavior of the old findIndex-based replay if a malformed list has
    // duplicate IDs: update its first occurrence and leave later copies alone.
    if (seen.has(process.id)) return process;
    seen.add(process.id);
    return pending.get(process.id) ?? process;
  });
  for (const [id, process] of pending) {
    if (seen.has(id)) continue;
    merged.push(process);
    seen.add(id);
  }
  return merged;
}
