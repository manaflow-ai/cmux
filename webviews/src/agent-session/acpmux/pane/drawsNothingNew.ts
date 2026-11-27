// Whether a client snapshot moves nothing the pane draws from the one before it (paneSnapshot.ts):
// the same rows array and every other field the same object, but for `connection` naming another
// live record's kind. The client emits once per frame a record arrived (direct.ts
// `emitInFrame(event.kind)`) and names that record's kind in `connection`, so a task note, a
// process update or a subagent's progress that changed no row and no field still read as a new
// snapshot and redrew the whole pane. On the recorded lane session
// (test/fixtures/chat-sim/replay-lane-session.ndjson) 407 of 3,563 snapshots are such, each an
// AcpmuxPane render of about 2.7 ms and its transcript's on an 8 vCPU runner under 4x-cores load
// (goal visible-frame-p95-under-load, profiled run 46067066265). O(fields): never reads a row.
import type { AcpmuxSnapshot } from "../model";
import { sameSettled } from "../liveToolOutput";

/// The single-word record kinds a live record can name in `connection`; every other record kind
/// is `snake_case` or dotted (`claude.system.task_progress`). The link states and the client's own
/// reasons ("connected", "attached", "failed", "disconnected", "session changed", "debug",
/// "connecting: …") are neither, so a change to or from one always draws.
const WORD_RECORD_KINDS: ReadonlySet<string> = new Set(["status", "response", "mode", "plan", "titled", "tools"]);
const RECORD_KIND = /^[a-z][a-z0-9]*(?:[._][a-z0-9]+)+$/;

function recordKind(connection: unknown): boolean {
  return typeof connection === "string" && (RECORD_KIND.test(connection) || WORD_RECORD_KINDS.has(connection));
}

export function drawsNothingNew(received: AcpmuxSnapshot, next: AcpmuxSnapshot): boolean {
  if (next === received) return true;
  if (next.rows !== received.rows) return false;
  const before = received as unknown as Record<string, unknown>;
  const after = next as unknown as Record<string, unknown>;
  const keys = Object.keys(after);
  if (keys.length !== Object.keys(before).length) return false;
  for (const key of keys) {
    if (Object.is(before[key], after[key])) continue;
    if (!(key in before)) return false;
    // A value-equal projection the client builds new on every snapshot (liveToolOutput.ts).
    if (key === "settled" && sameSettled(before[key], after[key])) continue;
    if (key === "connection" && recordKind(before[key]) && recordKind(after[key])) continue;
    return false;
  }
  return true;
}
