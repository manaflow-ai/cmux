// A stand-in History owner that answers `cmux.history.entries.list` as the daemon does with list
// follow (cmux-tui history_ops/follow.rs): each answer carries a `follow` cursor, and a list that
// sends the last one back gets only the entries that came or changed, each with its index, and the
// ids that left. `touch` is one change: an entry moves to the top with a new time (a command that
// ran again, an agent session that moved on). Used by the History delta detector and the bench.
import type { HistoryEntry, HistoryListParams } from "../../src/pages/history/types";
import { historyEntries } from "./deltaFixtures";

export class HistoryDaemon {
  entries: HistoryEntry[];
  /** Entries sent over all reads (whole or delta): what the page had to decode. */
  sent = 0;
  wholeReads = 0;
  deltaReads = 0;
  private next = 0;
  private held = new Map<string, { ids: string[]; prints: Map<string, string> }>();
  private clock = 1_800_000_000_000;

  constructor(count = 1000) {
    this.entries = historyEntries(count);
  }

  touch(index: number): void {
    const [entry] = this.entries.splice(index, 1);
    this.clock += 1000;
    this.entries.unshift({ ...entry, at_ms: this.clock, title: `${entry.title} (again)` });
  }

  reset(): void {
    this.sent = 0;
    this.wholeReads = 0;
    this.deltaReads = 0;
  }

  readonly answer = (op: string, raw: unknown): unknown => {
    if (op !== "cmux.history.entries.list") return {};
    const params = raw as HistoryListParams;
    const kinds = params.kinds ?? [];
    const rows = kinds.length ? this.entries.filter((entry) => kinds.includes(entry.kind)) : this.entries;
    const wire = rows.map((entry) => ({ ...entry, at_ms: String(entry.at_ms) }));
    const ids = wire.map((entry) => entry.id);
    const prints = new Map(wire.map((entry) => [entry.id, JSON.stringify(entry)]));
    const key = JSON.stringify({ kinds, text: params.text ?? "" });
    const before = params.follow ? this.held.get(params.follow) : undefined;
    this.next += 1;
    const follow = `test.${this.next}`;
    this.held.set(follow, { ids, prints });
    if (!before || before.ids.length === 0 || key !== this.keyOf(params.follow!)) {
      this.keys.set(follow, key);
      this.wholeReads += 1;
      this.sent += wire.length;
      return { entries: wire, revision: String(this.next), follow };
    }
    this.keys.set(follow, key);
    const at: number[] = [];
    const changed = wire.filter((entry, index) => {
      if (before.prints.get(entry.id) === prints.get(entry.id)) return false;
      at.push(index);
      return true;
    });
    const removed = before.ids.filter((id) => !prints.has(id));
    this.deltaReads += 1;
    this.sent += changed.length;
    return { entries: changed, revision: String(this.next), follow, delta: { removed, at } };
  };

  private readonly keys = new Map<string, string>();
  private keyOf(follow: string): string | undefined {
    return this.keys.get(follow);
  }
}
