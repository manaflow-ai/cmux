// Reads a recorded chat for the chat simulator's command lines (chat-sim.ts, chat-sim-watch.ts): a
// session directory's records (events/*.ndjson) or one NDJSON file's, cut to a seq range.
import { existsSync, readdirSync, readFileSync, statSync } from "node:fs";
import { join } from "node:path";
import type { EventRecord } from "../src/agent-session/acpmux/direct";
import { parseRecords } from "../src/agent-session/acpmux/sim/sanitize";

/** A session directory's records (events/*.ndjson), or one NDJSON file's. `~` is the home directory. */
export function readRecords(path: string): EventRecord[] {
  const at = path.replace(/^~/, process.env.HOME ?? "~");
  if (statSync(at).isDirectory()) {
    const dir = existsSync(join(at, "events")) ? join(at, "events") : at;
    return readdirSync(dir)
      .filter((name) => name.endsWith(".ndjson"))
      .sort()
      .flatMap((name) => parseRecords(readFileSync(join(dir, name), "utf8")));
  }
  return parseRecords(readFileSync(at, "utf8"));
}

export type RecordRange = { from?: number; to?: number; limit?: number };

/** The records with `from <= seq <= to`, at most `limit` of them. */
export function cutRecords(records: readonly EventRecord[], range: RecordRange): EventRecord[] {
  return records
    .filter((record) => record.seq >= (range.from ?? 0) && record.seq <= (range.to ?? Number.POSITIVE_INFINITY))
    .slice(0, range.limit ?? Number.POSITIVE_INFINITY);
}
