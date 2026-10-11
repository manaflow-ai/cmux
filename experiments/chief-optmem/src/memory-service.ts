import { type Block, blockId, Memory, MemoryError, run } from "./memory/index.ts";
import { type SqlExec, SqlMemoryStorage } from "./memory/sql-storage.ts";

/** memo commands that change the memory; they run in one transaction and may carry a key. */
const WRITES = new Set(["note", "nap", "forget", "config", "import"]);

export interface MemoResult {
  readonly stdout: string;
  readonly stderr: string;
  readonly code: number;
}

export interface MemoryView {
  readonly length: number;
  readonly pending: number;
  /** The wake lines as of now, or the block that must be compressed first. */
  readonly lines?: ReadonlyArray<string>;
  readonly missing?: string;
  /** The next compression: block id and memo's prompt for it. */
  readonly nap?: { readonly block: string; readonly prompt: string };
}

/** Today's date in a time zone, YYYY-MM-DD. */
export function dateIn(timeZone: string, now = new Date()): string {
  const parts = new Intl.DateTimeFormat("en-CA", {
    timeZone,
    year: "numeric",
    month: "2-digit",
    day: "2-digit",
  }).formatToParts(now);
  const get = (t: string) => parts.find((p) => p.type === t)!.value;
  return `${get("year")}-${get("month")}-${get("day")}`;
}

/**
 * One chief's memory over SQLite: the Durable Object adapter is a thin shell
 * around this, and tests run it on node:sqlite. Writes are serialized by the
 * caller (one object, one writer) and wrapped in `transaction`; a key makes a
 * retried write answer with the first result instead of writing twice.
 */
export class MemoryService {
  private readonly storage: SqlMemoryStorage;
  private readonly memory: Memory;

  constructor(
    private readonly sql: SqlExec,
    private readonly transaction: <T>(fn: () => T) => T,
    private readonly now: () => Date = () => new Date(),
  ) {
    sql(`CREATE TABLE IF NOT EXISTS mem_op (key TEXT PRIMARY KEY, result TEXT NOT NULL, at INTEGER NOT NULL)`);
    sql(`CREATE TABLE IF NOT EXISTS mem_meta (name TEXT PRIMARY KEY, value TEXT NOT NULL)`);
    this.storage = new SqlMemoryStorage(sql);
    this.memory = new Memory(this.storage, { today: () => dateIn(this.timeZone(), this.now()) });
  }

  timeZone(): string {
    return this.sql<{ value: string }>(`SELECT value FROM mem_meta WHERE name = 'tz'`)[0]?.value ?? "UTC";
  }

  setTimeZone(tz: string): void {
    dateIn(tz); // throws RangeError for an unknown zone
    this.sql(
      `INSERT INTO mem_meta (name, value) VALUES ('tz', ?) ON CONFLICT (name) DO UPDATE SET value = excluded.value`,
      tz,
    );
  }

  /** Runs one memo command line. `files` feeds `import <name>`. */
  memo(
    argv: ReadonlyArray<string>,
    options: { key?: string; files?: Readonly<Record<string, string>> } = {},
  ): MemoResult {
    if (!WRITES.has(argv[0] ?? "")) return run(this.memory, argv, options.files);
    // A refused write changes nothing, but its answer is still the answer for the key.
    return this.keyed(options.key, () => run(this.memory, argv, options.files));
  }

  /**
   * Appends several memories in one commit (one turn's events). Each text is
   * checked as memo checks a note; the whole batch fails on the first bad one.
   */
  note(texts: ReadonlyArray<string>, key?: string): { first: number; count: number } | { error: string } {
    return this.keyed(key, () => {
      try {
        const clean = texts.map((t) => this.memory.check(t));
        const date = dateIn(this.timeZone(), this.now());
        return { first: this.storage.append(clean.map((text) => ({ date, text }))), count: clean.length };
      } catch (e) {
        if (e instanceof MemoryError) return { error: e.message };
        throw e;
      }
    });
  }

  /** Writes the summary of the next pending block (refuses any other block). */
  nap(block: string, text: string, key?: string): MemoResult {
    return this.memo(["nap", block, text], key === undefined ? {} : { key });
  }

  view(): MemoryView {
    const length = this.storage.length();
    const pending = this.memory.pendingCount();
    const next = this.memory.nextBlock();
    const nap = next && { block: blockId(next), prompt: this.memory.napPrompt(next, pending - 1) };
    const cover = this.memory.coverLines();
    const base = { length, pending, ...(nap ? { nap } : {}) };
    return "missing" in cover ? { ...base, missing: blockId(cover.missing as Block) } : { ...base, lines: cover.lines };
  }

  private keyed<T>(key: string | undefined, write: () => T): T {
    if (key !== undefined) {
      const seen = this.sql<{ result: string }>(`SELECT result FROM mem_op WHERE key = ?`, key)[0];
      if (seen) return JSON.parse(seen.result) as T;
    }
    try {
      return this.transaction(() => {
        const result = write();
        if (key !== undefined) {
          this.sql(
            `INSERT INTO mem_op (key, result, at) VALUES (?, ?, ?)`,
            key,
            JSON.stringify(result),
            this.now().getTime(),
          );
        }
        return result;
      });
    } catch (e) {
      this.storage.refresh();
      throw e;
    }
  }
}
