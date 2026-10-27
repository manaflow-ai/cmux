// The prompts of a chat older than the transcript the pane holds, for the thread rail (Leo
// 2026-10-25: "if you haven't loaded in chats ... the session rails ... should be able to still,
// like, gradually load that stuff in"). The transcript opens on its tail and pages older turns in as
// the reader scrolls up; the rail shows every prompt of the chat from the start. acpmux pages any one
// record kind (paging.rs `EventFilter`, the exact kinds), so this reads only the records that say
// where a turn starts (TURN_KINDS: prompts, and what makes a prompt go on with the turn it stopped),
// newest first, a page at a time while the page is idle: a chat of thousands of turns downloads its
// prompts, never their replies and tool output. Each page becomes prompt rows as the transcript draws
// them (`user-<seq>`, with its promptId), so a tick keeps its key (turnKey), its bookmark and its
// place when the transcript later loads its turn.
import type { AcpmuxRow } from "../model";

/// The records a page reads: a prompt (`user_message`), and the ones that make a prompt sent now go
/// on with the turn it stopped instead of opening one (TurnStarts). At most 8 kinds (direct.ts attach).
export const TURN_KINDS = ["user_message", "queue_order", "turn_result", "queue_removed", "prompt_refused"];
/// One page: at most this many records, and at most this many bytes.
export const PROMPT_PAGE_LIMIT = 400;
export const PROMPT_PAGE_BYTES = 96 * 1024;
/// The most pages one chat reads (about 80 000 records), so a log that never says it is done stops.
export const PROMPT_PAGES_MAX = 200;
/// How long an idle callback may wait before a page is read anyway.
const IDLE_TIMEOUT_MS = 500;

export type PromptRecord = { seq: number; at?: number; kind: string; dir: string; msg?: any };
export type PromptPage = { events: PromptRecord[]; hasMore: boolean };

/// The earlier prompts as the rail reads them: a store of its own, apart from the pane's snapshot, so
/// a page that lands renders the rail alone, never the whole pane (direct.ts `earlier`).
export type EarlierPromptsStore = {
  subscribe(listener: () => void): () => void;
  /// The prompts older than the transcript, oldest first: the same list until they change.
  get(): readonly AcpmuxRow[];
};

type Idle = { request(run: () => void): () => void };

/// The page's idle time, or the next task where there is none (WebKit has no requestIdleCallback).
const idle: Idle = {
  request(run) {
    const scope = globalThis as typeof globalThis & {
      requestIdleCallback?: (run: () => void, options?: { timeout: number }) => number;
      cancelIdleCallback?: (handle: number) => void;
    };
    if (scope.requestIdleCallback && scope.cancelIdleCallback) {
      const handle = scope.requestIdleCallback(run, { timeout: IDLE_TIMEOUT_MS });
      return () => scope.cancelIdleCallback!(handle);
    }
    const handle = setTimeout(run, 0);
    return () => clearTimeout(handle);
  },
};

/// The earlier prompts of the shown chat. `start` begins reading below a seq; each page that lands
/// calls `changed`. It stops on its own once acpmux has nothing older, after PROMPT_PAGES_MAX pages,
/// or when a read fails; `stop` (a chat switch, the client closing) ends it at once.
/// Which prompts open a turn, over records oldest first, as the transcript decides it (direct.ts, the
/// `user_message` and `turn_result` cases): a steer never does (`msg.steer`); nor does a prompt sent
/// now (`queue_order` with `next` while a turn ran) once the turn it stopped ended without failing
/// before it ran (`continues`, turnStart.ts). A prompt removed or refused meanwhile, or another one
/// opening a turn first, ends that. A page may start inside a turn because its opener is in an
/// older page. Copy and compare the complete state at page boundaries so adding older context
/// re-evaluates newer records until their state converges.
export class TurnStarts {
  private open = false;
  private interrupting?: string;
  continued?: string;

  copy(): TurnStarts {
    const copy = new TurnStarts();
    copy.open = this.open;
    copy.interrupting = this.interrupting;
    copy.continued = this.continued;
    return copy;
  }

  same(other: TurnStarts | undefined): boolean {
    return (
      !!other &&
      this.open === other.open &&
      this.interrupting === other.interrupting &&
      this.continued === other.continued
    );
  }

  /// Whether `record` is a prompt that opens a turn.
  opens(record: PromptRecord): boolean {
    const msg = record.msg ?? {};
    const promptId = typeof msg.promptId === "string" ? msg.promptId : undefined;
    switch (record.kind) {
      case "user_message": {
        if (record.dir !== "mux" || msg.steer === true) return false;
        const continues = promptId !== undefined && promptId === this.continued;
        this.continued = undefined;
        if (promptId !== undefined && promptId === this.interrupting) this.interrupting = undefined;
        this.open = true;
        return !continues;
      }
      case "queue_order":
        if (msg.next === true && this.open && promptId) this.interrupting = promptId;
        return false;
      case "queue_removed":
      case "prompt_refused":
        if (promptId === this.interrupting) this.interrupting = undefined;
        if (promptId === this.continued) this.continued = undefined;
        return false;
      case "turn_result":
        this.open = false;
        if (this.interrupting !== undefined && String(msg.status ?? "completed") !== "failed")
          this.continued = this.interrupting;
        this.interrupting = undefined;
        return false;
      default:
        return false;
    }
  }
}

/// A page's raw events, output state, and current opening prompts/rows, oldest first.
/// Even rowless pages are kept: a queue order, result, or refusal can affect a later prompt.
type Chunk = { events: PromptRecord[]; records: PromptRecord[]; rows: AcpmuxRow[]; end?: TurnStarts };

/// The earlier prompts of the shown chat. `start` begins reading below a seq; each page that lands
/// calls `changed`. It stops on its own once acpmux has nothing older, after PROMPT_PAGES_MAX pages,
/// or when a read fails; `stop` (a chat switch, the client closing) ends it at once. A page appends
/// its own prompts (no copy of the ones before); the list the rail reads is built once per `shown`
/// that follows a change. `changed` is called once the prompts have grown by half since it last was
/// (or by half a page), and when the reading ends: the rail, which draws its ticks again on each call,
/// draws O(log n) times for n prompts, so the whole load costs it O(n), never a draw per page.
export class EarlierPrompts {
  /// Every page, including pages without prompts: their events carry boundary state.
  /// Pages are newest first; events within each page are oldest first.
  private chunks: Chunk[] = [];
  private sessionId?: string;
  /// Where reading started, and the oldest seq read so far.
  private top = 0;
  private before = 0;
  private pages = 0;
  private run = 0;
  private cancel?: () => void;
  private done = true;
  /// Bumped by every change to the prompts; `shown` builds its list again once per version.
  private version = 0;
  /// The prompts held, and how many there were when `changed` was last called.
  private count = 0;
  private told = 0;
  /// The last `shown` answer: the whole list, oldest first, and the one cut at its bound.
  private memo?: { version: number; all: AcpmuxRow[]; below: number; shown: readonly AcpmuxRow[] };

  constructor(
    private read: (sessionId: string, beforeSeq: number) => Promise<PromptPage>,
    /// A prompt record that opens a turn as the transcript draws it, or undefined for one it does not draw.
    private toRow: (record: PromptRecord) => AcpmuxRow | undefined,
    private changed: () => void,
    private schedule: Idle = idle,
  ) {}

  /// Reads the prompts of `sessionId` older than `beforeSeq`. Asked again for the same chat it reads
  /// nothing more: the transcript only grows older from where it started, which this already covers.
  /// A start above that (the transcript dropped its tail for a newer page) reads again from there.
  start(sessionId: string, beforeSeq: number): void {
    if (this.sessionId === sessionId && beforeSeq <= this.top) return;
    this.stop();
    this.sessionId = sessionId;
    this.top = beforeSeq;
    this.before = beforeSeq;
    this.done = beforeSeq <= 1;
    if (!this.done) this.next();
  }

  /// Ends any reading and forgets the prompts read.
  stop(): void {
    this.run += 1;
    this.cancel?.();
    this.cancel = undefined;
    this.done = true;
    this.pages = 0;
    this.top = 0;
    this.sessionId = undefined;
    if (this.chunks.length) {
      this.chunks = [];
      this.version += 1;
    }
    this.count = 0;
    this.told = 0;
  }

  /// What a prompt shows changed (a sender became known, incomingMessage.ts): the rows are built
  /// again from their records, as the transcript reads its own again.
  refresh(): void {
    if (!this.chunks.length) return;
    for (const chunk of this.chunks) chunk.rows = this.rowsOf(chunk.records);
    this.version += 1;
    this.changed();
  }

  /// Whether pages are still to come.
  get loading(): boolean {
    return !this.done;
  }

  private rowsOf(records: PromptRecord[]): AcpmuxRow[] {
    const rows: AcpmuxRow[] = [];
    for (const record of records) {
      const row = this.toRow(record);
      if (row) rows.push(row);
    }
    return rows;
  }

  private next(): void {
    const run = this.run;
    this.cancel = this.schedule.request(() => {
      this.cancel = undefined;
      if (run === this.run) void this.page(run);
    });
  }

  private async page(run: number): Promise<void> {
    const sessionId = this.sessionId;
    if (!sessionId || this.done) return;
    let page: PromptPage;
    try {
      page = await this.read(sessionId, this.before);
    } catch {
      if (run === this.run) {
        this.done = true;
        // A failed page is a terminal stop too: publish rows accumulated since the last batch.
        if (this.count !== this.told) {
          this.told = this.count;
          this.changed();
        }
      }
      return;
    }
    if (run !== this.run) return;
    this.pages += 1;
    const records = page.events.filter((event) => event.seq < this.before).sort((a, b) => a.seq - b.seq);
    const more = page.hasMore && records.length > 0;
    if (records.length) {
      this.before = records[0]!.seq;
      this.chunks.push({ events: records, records: [], rows: [] });
      // Re-evaluate toward newer pages with ALL turn state, including interrupting and continued.
      // Stop when a page's output state converges: every newer page then has the same input as
      // before. No history is revisited for streaming tokens; only an index page triggers this.
      const starts = new TurnStarts();
      for (let index = this.chunks.length - 1; index >= 0; index -= 1) {
        const chunk = this.chunks[index]!;
        const opening = chunk.events.filter((record) => starts.opens(record));
        if (opening.length !== chunk.records.length || opening.some((record, at) => record !== chunk.records[at])) {
          const held = new Map(chunk.rows.map((row) => [row.id, row]));
          const rows: AcpmuxRow[] = [];
          for (const record of opening) {
            const row = held.get(`user-${record.seq}`) ?? this.toRow(record);
            if (row) rows.push(row);
          }
          this.count += rows.length - chunk.rows.length;
          chunk.records = opening;
          chunk.rows = rows;
          this.version += 1;
        }
        if (starts.same(chunk.end)) break;
        chunk.end = starts.copy();
      }
    }
    this.done = !more || this.before <= 1 || this.pages >= PROMPT_PAGES_MAX;
    if (!this.done) this.next();
    if (this.done || this.count - this.told >= Math.max(PROMPT_PAGE_LIMIT / 4, this.told / 2)) {
      this.told = this.count;
      this.changed();
    }
  }

  /// The prompts older than `belowSeq` (the oldest the transcript holds), oldest first: the same list
  /// while neither the prompts nor the bound changed, so a streamed token's snapshot does no work.
  shown(belowSeq: number | undefined): readonly AcpmuxRow[] {
    const below = belowSeq ?? Infinity;
    const memo = this.memo;
    if (memo && memo.version === this.version && memo.below === below) return memo.shown;
    let all = memo && memo.version === this.version ? memo.all : undefined;
    if (!all) {
      all = [];
      for (let at = this.chunks.length - 1; at >= 0; at -= 1) for (const row of this.chunks[at]!.rows) all.push(row);
    }
    // Binary search: the rows are in seq order.
    let low = 0;
    let high = all.length;
    while (low < high) {
      const middle = (low + high) >>> 1;
      if (rowSeq(all[middle]!) < below) low = middle + 1;
      else high = middle;
    }
    const shown = low === all.length ? all : all.slice(0, low);
    this.memo = { version: this.version, all, below, shown };
    return shown;
  }
}

const rowSeq = (row: AcpmuxRow) => Number(row.id.slice(row.id.indexOf("-") + 1));
