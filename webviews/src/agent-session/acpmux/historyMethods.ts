import {
  COMPACTION_REPEAT_WINDOW,
  INDEXED_PAGE_RADIUS,
  LAG_RETRY_MS,
  METHOD_NOT_FOUND,
  NATIVE_PAGES_PER_ASK,
  OLDER_AHEAD_PAGES,
  OLDER_PAGE_BYTES,
  OLDER_PAGE_RECORDS,
  OLDER_PAGES_PER_ASK,
  OLDER_REST_PAGE_BYTES,
  OLDER_REST_PAGE_RECORDS,
  WINDOW_PARALLEL_PAGES,
  firstHeldFrom,
  mergeEventRecords,
  prependOlderEventRecords,
  records,
  seedRoots,
  sessionUpdate,
  startsTurn,
  stillRunning,
  compactionOf,
} from "./direct";
import type { EventRecord } from "./direct";
import { withAwaitingCall } from "./hiddenTools";
import { SubagentFold } from "./subagents/subagentFold";
import type { AcpmuxActivity, AcpmuxCompaction, AcpmuxRow } from "./model";
import { KEPT_EVENTS } from "./tailCache";
import { PRESET_APPROVAL_KINDS } from "./attachParams";

const historyMethods: Record<string, (...args: any[]) => any> = {
  async loadThrough(seq: number): Promise<boolean> {
    const generation = this.selectionGeneration;
    const held = () => generation === this.selectionGeneration && this.firstSeq !== undefined && this.firstSeq <= seq;
    // The prompt index gives us the target's sequence before its transcript page is held. Fetch
    // that window first, then warm one page on each side for the next scrub step. If an older
    // daemon cannot serve the bounded read, the established page walker remains the fallback.
    const indexed = this.promptIndex?.rows?.some((row) => row.id === `user-${seq}`) ? this.indexedPage(seq) : undefined;
    if (indexed) {
      const page = await indexed;
      if (generation !== this.selectionGeneration || this.selectedSessionId === undefined) return false;
      if (page.some((event) => event.seq === seq)) {
        this.mergeIndexedPage(page);
        void this.indexedPage(Math.max(1, seq - INDEXED_PAGE_RADIUS));
        void this.indexedPage(seq + INDEXED_PAGE_RADIUS);
        if (held()) return true;
      }
    }
    // Each loadOlder call publishes one bounded page (or a rail jump's window), so keep walking
    // until the target is held. A fixed iteration cap here would make a far minimap jump fail once a
    // long chat spans more than that many pages.
    for (;;) {
      const from = this.firstSeq;
      if (held()) return true;
      if (generation !== this.selectionGeneration || from === undefined || !this.seqHistoryLeft()) return false;
      await this.loadOlder(seq);
      if (this.firstSeq === from) return held();
    }
  },

  /// Pages older transcript events in without reattaching, so the live summary,
  /// queue and permission stay as they are. A page that lands after the
  /// selection changed belongs to another session and is dropped.
  /// `through`: read on until the record at that seq is held (a rail jump, `loadThrough`), not only
  /// until an older turn starts. `fill`: the held rows do not fill the view; the read lands with the
  /// first page that starts an older turn. `rising`: the reader is scrolling up now (the transcript's
  /// OlderAhead); only then does a read ask for the big page (OLDER_PAGE_BYTES) and read pages ahead.
  loadOlder(through?: number, fill = false, rising = false): Promise<void> {
    // A chat on the store pages from it.
    if (this.selectedSessionId && this.chatRows.holds(this.selectedSessionId))
      return Promise.resolve(void this.chatRows.page(this.selectedSessionId));
    if (!this.canPageOlder()) return Promise.resolve();
    if (this.loadingOlder) return this.loadingOlder;
    // An ask inside the back-off after a failed page waits it out, then reads. One that returned
    // at once read nothing, and the transcript that asked at the very top had no scroll left to
    // ask again with: a 720-turn chat stopped paging for good (Leo 2026-10-21).
    const wait = this.olderRetryAt - Date.now();
    const generation = this.selectionGeneration;
    const pagingEpoch = this.olderPagingEpoch;
    const read =
      wait > 0
        ? this.olderDelay
            .wait(wait)
            .then((ready) =>
              ready && this.canPageOlder(pagingEpoch) && generation === this.selectionGeneration
                ? this.fetchOlder(pagingEpoch, through, fill, rising)
                : undefined,
            )
        : this.fetchOlder(pagingEpoch, through, fill, rising);
    const loading = read
      .catch((error: unknown) => {
        if (this.canPageOlder(pagingEpoch) && generation === this.selectionGeneration)
          this.olderRetryAt = Date.now() + 2_000;
        throw error;
      })
      .finally(() => {
        if (this.loadingOlder === loading) this.loadingOlder = undefined;
      });
    this.loadingOlder = loading;
    return loading;
  },
  /// Older pages read ahead of the reader (`readOlderAhead`), by the `beforeSeq` each was asked with, for
  /// the chat, visit, held history and paging epoch they were read in (`olderKey`).
  /// The records an older page read but did not land (`fetchOlder` keeps whole turns, so the end
  /// of a turn further back waits): `before` is the oldest seq read, `from` the held records' first
  /// seq they end at. The next ask reads on from `before` and lands them with its page, so no read
  /// asks again for records already read (and read-ahead chains from `before`).
  /// The carried records for this chat's next older read, while they still end where the held ones
  /// begin; otherwise none.
  olderCarryFor(sessionId: string, pagingEpoch: number) {
    const carry = this.olderCarry;
    return carry?.key === this.olderKey(sessionId, pagingEpoch) && carry.from === this.firstSeq ? carry : undefined;
  },
  olderKey(sessionId: string, pagingEpoch: number): string {
    return `${sessionId}\u0000${this.selectionGeneration}\u0000${this.historyEpoch}\u0000${pagingEpoch}`;
  },
  /// The older page of `sessionId` that ends before `before`: the one read ahead for it, else a read.
  /// `rest`: the reader is not scrolling up, so a read asks for the rest page (OLDER_REST_PAGE_BYTES).
  olderPage(sessionId: string, before: number, pagingEpoch: number, rest = false): Promise<any> {
    const ahead = this.olderAhead;
    const kept = ahead?.key === this.olderKey(sessionId, pagingEpoch) ? ahead.pages.get(before) : undefined;
    if (kept) {
      ahead!.pages.delete(before);
      return kept;
    }
    return this.typed("_acpmux/events", {
      sessionId,
      beforeSeq: before,
      limit: rest ? OLDER_REST_PAGE_RECORDS : OLDER_PAGE_RECORDS,
      maxBytes: rest ? OLDER_REST_PAGE_BYTES : OLDER_PAGE_BYTES,
      // acpmux's "transcript" leaves out the preset approval records (paging.rs): a card older
      // than the attach's page comes with the older page that holds it, on a local acpmux as at
      // attach (three kinds, within a remote cmux-tui's eight either way).
      kinds: ["transcript", ...(this.localOrigin ? PRESET_APPROVAL_KINDS : [])],
    });
  },
  /// Reads the next OLDER_AHEAD_PAGES older pages after an older read lands, one after another, and
  /// keeps them for the next ask (`olderPage`). A page that fails is dropped, and the ask reads it
  /// again. Another chat, visit, held history or paging epoch keys the kept pages out.
  readOlderAhead(pagingEpoch: number): void {
    const sessionId = this.selectedSessionId;
    if (!sessionId || this.historyExhausted || !this.firstSeq || this.firstSeq <= 1 || !this.canPageOlder(pagingEpoch))
      return;
    const key = this.olderKey(sessionId, pagingEpoch);
    // Reuse only the next contiguous chain. Trimming a partial turn changes its cursor;
    // unrelated pages from previous chains must not accumulate across a long scroll.
    const previous = this.olderAhead?.key === key ? this.olderAhead.pages : undefined;
    const pages = new Map<number, Promise<any>>();
    const ahead = { key, pages };
    this.olderAhead = ahead;
    // Past the records already read and carried (`olderCarry`), where the next ask reads.
    let before = this.olderCarryFor(sessionId, pagingEpoch)?.before ?? this.firstSeq;
    void (async () => {
      for (let read = 0; read < OLDER_AHEAD_PAGES; read++) {
        if (this.olderAhead !== ahead || !this.canPageOlder(pagingEpoch)) return;
        const asked = before;
        const page = previous?.get(asked) ?? this.olderPage(sessionId, asked, pagingEpoch);
        pages.set(asked, page);
        let result: any;
        try {
          result = await page;
        } catch {
          if (pages.get(asked) === page) pages.delete(asked);
          return;
        }
        const events = records(result?.events);
        if (result?.hasMore !== true || events.length === 0 || events[0]!.seq >= asked) return;
        before = events[0]!.seq;
      }
    })();
  },
  /// The records from below `through` up to `from` (exclusive), newest page first, read at once: the
  /// stretch is cut into slots of OLDER_PAGE_RECORDS seqs, and each slot's page (the newest records
  /// before its top) is asked together, WINDOW_PARALLEL_PAGES at a time. A page reaches at least its
  /// slot's foot unless its byte cap ends it first; that gap is read page by page before the next
  /// slot's records are taken, so what comes back holds every record from its oldest page up.
  /// Undefined when the read went stale (another chat, visit, held history or paging epoch).
  async readWindow(
    sessionId: string,
    from: number,
    through: number,
    pagingEpoch: number,
    stale: () => boolean,
  ): Promise<{ pages: EventRecord[][]; before: number; more: boolean } | undefined> {
    const pages: EventRecord[][] = [];
    let before = from;
    let more = true;
    const take = (result: any) => {
      const page = records(result?.events).filter((event) => event.seq < before);
      if (page.length > 0) {
        pages.push(page);
        before = page[0]!.seq;
      }
      more = result?.hasMore === true && page.length > 0;
      return page.length > 0;
    };
    // A slot's page the gap reads above already passed (they ran below its top past a byte cap)
    // holds nothing older than `before`; that says nothing of what is left below, so it is
    // skipped, and the next round reads on from `before`. Only an empty read at `before` ends it.
    const takeSlot = (result: any) => {
      if (records(result?.events).some((event) => event.seq < before)) take(result);
    };
    while (more && before > through && before > 1) {
      const slots: number[] = [];
      // Down to the first slot that starts at or below `through`: its page holds the records just
      // above the place, and usually the prompt of the turn the place is in.
      for (let top = before; slots.length < WINDOW_PARALLEL_PAGES && top > 1; top -= OLDER_PAGE_RECORDS) {
        slots.push(top);
        if (top <= through) break;
      }
      const results = await Promise.all(slots.map((top) => this.olderPage(sessionId, top, pagingEpoch)));
      if (stale()) return undefined;
      for (let slot = 0; slot < slots.length && more; slot++) {
        // The page above ended short of this slot (its byte cap): read the gap page by page.
        while (more && before > slots[slot]!) {
          const result = await this.olderPage(sessionId, before, pagingEpoch);
          if (stale()) return undefined;
          if (!take(result)) more = false;
        }
        // A slot read at `before` itself is the read that ends the window when it comes back empty.
        if (more) (slots[slot] === before ? take : takeSlot)(results[slot]);
      }
    }
    return { pages, before, more };
  },
  async fetchOlder(
    pagingEpoch = this.olderPagingEpoch,
    through?: number,
    _fill = false,
    rising = false,
  ): Promise<void> {
    if (!this.canPageOlder(pagingEpoch)) return;
    if (this.selectedSessionId && !this.seqHistoryLeft() && this.nativeBefore() !== undefined)
      return this.fetchNativeOlder();
    if (!this.selectedSessionId || !this.firstSeq || this.firstSeq <= 1 || this.historyExhausted) return;
    const sessionId = this.selectedSessionId;
    const generation = this.selectionGeneration;
    const epoch = this.historyEpoch;
    // The prompt drawn first: the open turn's opener when the held events start mid-turn.
    const drawnFrom = this.turnOpener?.seq ?? this.firstSeq;
    const opensOlderTurn = (event: EventRecord) => startsTurn(event) && event.seq < drawnFrom;
    // Keep the target's preceding turn, including when byte caps end a page at the target prompt.
    const opensAbove = (event: EventRecord) => through !== undefined && startsTurn(event) && event.seq < through;
    const stale = () =>
      !this.canPageOlder(pagingEpoch) ||
      generation !== this.selectionGeneration ||
      this.selectedSessionId !== sessionId ||
      epoch !== this.historyEpoch;
    // Publish each page as soon as it arrives. A long active turn must not hide the first readable
    // older records behind a whole-turn scan. Records before the oldest older turn start finish a
    // turn further back and remain for the next bounded ask; on the final page there is no next
    // ask, so its prefix stays too (native adoption history can begin before its first prompt).
    // What the last ask read but left for this one (`olderCarry`): it lands with this ask's page.
    const key = this.olderKey(sessionId, pagingEpoch);
    let carried = this.olderCarryFor(sessionId, pagingEpoch);
    const publish = (read: EventRecord[], pageMore: boolean) => {
      const older = carried ? [...read, ...carried.events] : read;
      carried = undefined;
      this.olderCarry = undefined;
      // The open landed inside the turn on screen: the page holding its prompt makes it whole, and
      // the rest of a longer turn above it waits for the next ask (the user, 2026-11-03: a reply
      // starting mid-sentence under its prompt, and nothing above).
      const cutOpener =
        this.turnOpener && this.firstSeq !== undefined && this.turnOpener.seq < this.firstSeq
          ? this.turnOpener.seq
          : undefined;
      let start = pageMore ? older.findIndex(opensOlderTurn) : -1;
      if (start < 0 && pageMore && cutOpener !== undefined) start = older.findIndex((event) => event.seq >= cutOpener);
      const page = start > 0 ? older.slice(start) : older;
      if (page.length === 0) return;
      // The records left above the page were read: the next ask reads on past them, not again.
      if (start > 0)
        this.olderCarry = { key, before: older[0]!.seq, from: page[0]!.seq, events: older.slice(0, start) };
      // The held records start inside a turn, and this page brings that turn's start: refold it whole
      // once, so it draws as reading the whole record does. Pages inside the turn before it fold
      // incrementally (`foldOlder`), so a long turn costs one refold, not one per page.
      const completesCutTurn =
        this.events.length > 0 && !startsTurn(this.events[0]!) && page.some((event) => startsTurn(event));
      this.events = prependOlderEventRecords(page, this.events);
      this.sawPrompts(page);
      // A page exposing a forced result can establish a fence at a prompt already drawn below it.
      // Replay that boundary chronologically; merging rows cannot recover the held prompt's effect.
      const crossesStop = page.some(
        (event) =>
          event.dir === "mux" &&
          event.kind === "turn_result" &&
          event.msg?.cancelForced === true &&
          typeof event.msg?.turnId === "string",
      );
      if (
        !completesCutTurn &&
        !crossesStop &&
        this.compactionFenceSeq === undefined &&
        this.retiredCompactionTurnId === undefined
      )
        this.foldOlder(page);
      else this.rebuildKeepingLiveState();
      this.historyExhausted = false;
      this.emit("history");
    };
    let more = true;
    let before = carried?.before ?? this.firstSeq;
    let windowed = false;
    let foundThrough = through === undefined;
    // A rail jump far back reads the window down to its target at once (`readWindow`) and lands it.
    if (through !== undefined && through < before) {
      const window = await this.readWindow(sessionId, before, through, pagingEpoch, stale);
      if (!window || stale()) return;
      windowed = true;
      foundThrough = window.pages.some((page) => page.some(opensAbove));
      before = window.before;
      more = window.more;
      publish(window.pages.reverse().flat(), more);
    }
    // The reader asked for this (scrolling up, or a rail jump to a place): the big page, and pages ahead.
    const reading = rising || through !== undefined;
    // A page can draw nothing above the first row: a prompt queued with a big paste or image is a
    // page of its own, and every page of a long turn the open landed in is that turn's. Each ask
    // reads OLDER_PAGES_PER_ASK pages and moves `historyFrom`, which makes the transcript ask again.
    for (let pages = 0; more && pages < OLDER_PAGES_PER_ASK && (!windowed || !foundThrough); pages++) {
      if (!this.canPageOlder(pagingEpoch)) return;
      const result = await this.olderPage(sessionId, before, pagingEpoch, !reading);
      if (stale()) return;
      const page = records(result?.events);
      const pageMore = result?.hasMore === true && page.length > 0 && page[0]!.seq < before;
      publish(page, pageMore);
      more = pageMore;
      if (page.length > 0) before = Math.min(before, page[0]!.seq);
    }
    this.historyExhausted = !more || (this.firstSeq ?? 1) <= 1;
    if (this.historyExhausted) this.emit("history");
    // Pages ahead only for a reader on the way up (or a rail jump): a chat at rest reads no 4 MiB it may never show.
    if (reading) this.readOlderAhead(pagingEpoch);
  },

  /// Pages older turns in from the chat's Claude Code transcript, past the newest page its log was
  /// seeded with (`nativeBefore`). acpmux sends them as the records adopting logs, numbered below 1
  /// (oldest first, the same numbers for the same cursor), so they sort above every logged record
  /// and stay out of the log's own bookkeeping: `seqHistoryLeft` is false once one is held. Records
  /// the pane already holds (a kept tail drew them) are dropped, and the read goes on to an older
  /// page. Each page is whole turns that end, so it folds above the held rows (`foldOlder`) and
  /// the transcript keeps the reader's place as for any older page.
  async fetchNativeOlder(): Promise<void> {
    const sessionId = this.selectedSessionId!;
    const generation = this.selectionGeneration;
    const epoch = this.historyEpoch;
    let before = this.nativeBefore();
    let mark = this.nativeNext?.epoch === epoch ? this.nativeNext.mark : this.nativeSeed?.mark;
    // A kept tail cut inside a native turn holds that turn's end only (KEPT_EVENTS): the turn comes
    // again whole with its page, so the part held goes and the rows are drawn again.
    const cut = this.events[0] !== undefined && this.events[0].seq < 1 && this.events[0].kind !== "turn_started";
    const whole = cut ? this.events.find((event) => event.seq >= 1 || event.kind === "turn_started") : this.events[0];
    const heldFrom = whole?.seq ?? Infinity;
    let older: EventRecord[] = [];
    for (let pages = 0; before !== undefined && before > 0 && pages < NATIVE_PAGES_PER_ASK; pages++) {
      let result: any;
      try {
        result = await this.request("_acpmux/native_history", { sessionId, before, mark }, 15_000);
      } catch (error) {
        // An older daemon serves no pages, an older host relays none, a peer that serves none is
        // never asked, and a Web client may not read the transcript: the chat stops paging, as at
        // its first turn.
        const { code, reason } = (error ?? {}) as { code?: unknown; reason?: unknown };
        const unserved =
          code === METHOD_NOT_FOUND ||
          code === "transport.method_refused" ||
          reason === "transcriptRead.unsupported" ||
          reason === "transcriptRead.remote" ||
          reason === "transcriptRead.stale";
        if (!unserved) throw error;
        result = { events: [], before: 0 };
      }
      if (generation !== this.selectionGeneration || this.selectedSessionId !== sessionId) return;
      if (epoch !== this.historyEpoch) return;
      const page = records(result?.events).filter(
        (event) => typeof event?.seq === "number" && event.seq < 1 && event.seq < heldFrom,
      );
      older = [...page, ...older];
      const next = Number(result?.before);
      // A cursor moves back, or the transcript is done.
      before = Number.isFinite(next) && next > 0 && next < before ? next : 0;
      mark = typeof result?.mark === "string" ? result.mark : undefined;
      if (older.some(startsTurn)) break;
    }
    this.nativeNext = { epoch, before: before ?? 0, mark };
    if (cut) this.events = this.events.filter((event) => event.seq >= heldFrom);
    if (older.length > 0) {
      this.events = mergeEventRecords(older, this.events);
      this.sawPrompts(older);
    }
    if (cut) this.rebuildKeepingLiveState();
    else if (older.length > 0) this.foldOlder(older);
    this.emit("history");
  },

  /// Folds whole turns older than every held event into rows above them, without folding the held
  /// events again: the cost of a page stays the page's however much history is loaded. The fold
  /// starts from a clean turn and leaves the live state (an open turn, its stream and typing row,
  /// asks, commands, usage, prompts in flight) as the held events made it.
  foldOlder(older: EventRecord[]): void {
    const live = {
      turnOpen: this.turnOpen,
      turnStartedAtMs: this.turnStartedAtMs,
      turnPromptAtMs: this.turnPromptAtMs,
      // The running turn's prompt is the held events', never an older page's.
      turnPrompt: this.turnPrompt,
      turnTokens: this.turnTokens,
      turnTokenSplit: this.turnTokenSplit,
      streamingAssistant: this.streamingAssistant,
      streamingAssistantMessageId: this.streamingAssistantMessageId,
      // The live reply's segment (`replySegment`): the page's chunks never take its place.
      streamingSegment: this.streamingSegment,
      assistantCut: this.assistantCut,
      streamingActivity: this.streamingActivity,
      planRow: this.planRow,
      progressRow: this.progressRow,
      progressSuperseded: this.progressSuperseded,
      messageRows: this.messageRows,
      toolRows: this.toolRows,
      toolRowScopes: this.toolRowScopes,
      currentToolScope: this.currentToolScope,
      planCalls: this.planCalls,
      subagents: this.subagents,
      summary: this.summary,
      queue: this.queue,
      pendingPermission: this.pendingPermission,
      waitingPermissions: this.waitingPermissions,
      pendingSecret: this.pendingSecret,
      groupedPermissions: this.groupedPermissions,
      openQuestions: this.openQuestions,
      heldEdits: this.heldEdits,
      usage: this.usage,
      forkedAtSeq: this.forkedAtSeq,
      optimisticPromptRows: this.optimisticPromptRows,
      promptRowKeys: this.promptRowKeys,
      optimisticPromptTexts: this.optimisticPromptTexts,
      promptAccepts: this.promptAccepts,
      compactionHeardAt: this.compactionHeardAt,
      runningTurnId: this.runningTurnId,
      stopTurnId: this.stopTurnId,
      // Older events never move the live compaction fence (loadOlder folds only pages that cannot set it).
      retiredCompactionTurnId: this.retiredCompactionTurnId,
      compactionFenceSeq: this.compactionFenceSeq,
      // A Send now still waiting for the cancel it causes is the live turn's, never the page's.
      interrupting: this.interrupting,
      awaiting: this.awaiting,
    };
    const held = new Map(this.rows);
    this.runningTurnId = undefined;
    this.turnOpen = false;
    this.turnStartedAtMs = undefined;
    this.turnPromptAtMs = undefined;
    this.turnPrompt = undefined;
    this.turnTokens = undefined;
    this.turnTokenSplit = undefined;
    this.lastReplyRow = undefined;
    this.streamingAssistant = undefined;
    this.streamingAssistantMessageId = undefined;
    this.streamingSegment = undefined;
    this.assistantCut = false;
    this.streamingActivity = undefined;
    this.planRow = undefined;
    this.progressRow = undefined;
    this.progressSuperseded = false;
    this.messageRows = new Map();
    this.toolRows = new Map();
    this.toolRowScopes = new Map();
    // An older page's records are older than every live turn: until the page's own prompt or turn
    // start sets it, the turn they belong to is unknown, never the live one.
    this.currentToolScope = undefined;
    this.planCalls = new Set();
    this.bgDoneTurns = new Map();
    this.subagents = new SubagentFold(this.subagentStops);
    // An older page replays persisted records too: seed the native roots as the full replay does.
    seedRoots(this.subagents, this.summary);
    this.groupedPermissions = new Map();
    this.waitingPermissions = new Map();
    this.openQuestions = new Set();
    this.heldEdits = new Set();
    // An older prompt never settles one still sending, however alike their text.
    this.optimisticPromptRows = new Map();
    this.promptRowKeys = new Map();
    this.optimisticPromptTexts = new Map();
    this.promptAccepts = new Map();
    this.compactionHeardAt = new Map();
    this.interrupting = undefined;
    this.awaiting = undefined;
    this.foldingBelow = this.firstSeq ?? Infinity;
    this.heldPromptRowKeys = live.promptRowKeys;
    this.presetApprovalRemoved.clear();
    const below = this.foldingBelow;
    let pageMade: readonly string[] | undefined;
    this.rows.beginPrepend(below);
    try {
      for (const event of [...older].sort((a, b) => a.seq - b.seq)) {
        this.firstSeq = Math.min(this.firstSeq ?? event.seq, event.seq);
        this.reduce(event);
      }
    } finally {
      // The rows the page made, read below instead of every row the chat holds.
      pageMade = this.rows.prependedRows();
      this.rows.endPrepend();
      this.foldingBelow = undefined;
      this.heldPromptRowKeys = undefined;
    }
    // A page can split a tool call: its completed update may have been held first, then the
    // older page brings the call opener. Keep the held row as the authoritative later state and
    // remove the page's duplicate item, while retaining page-only calls in the incremental fold.
    // `toolRows` is keyed by call id and is intentionally reset at every prompt. Capture every
    // page row before restoring the live map; adapters may reuse an id in several turns.
    const pageToolRows: { callId: string; rowId: string; item: AcpmuxActivity; scope?: string }[] = [];
    for (const rowId of new Set(pageMade)) {
      const row = this.rows.get(rowId);
      if (!row || held.has(rowId) || row.kind !== "activity") continue;
      for (const item of row.items ?? []) {
        if (item.tool) pageToolRows.push({ callId: item.tool.id, rowId, item, scope: this.toolRowScopes.get(rowId) });
      }
    }
    const pageMessageRows = new Map<string, string[]>();
    for (const [messageId, rowIds] of this.messageRows)
      pageMessageRows.set(
        messageId,
        rowIds.filter((rowId) => !held.has(rowId)),
      );
    this.timeTurnsOpenedAbove(below);
    this.sinceStale = true;
    // The held events' compactions take up the ones the page left open, in order, as reading the
    // whole record does (`compaction` above). One whose first record is a running note continues a
    // compaction the page left running, or noted as failed while it may go on (a forced Stop, or an
    // account switch's that runs between turns), if that was heard on time. One whose first record
    // already says how it ended found nothing open in the held events, so it ends the latest
    // compaction still open, however long after: the end goes on that row, where the compaction
    // started, and the held row goes, so a page further back takes nothing more for it.
    // How a held compaction's first record says it stands; undefined when that record is not held.
    const openedAs = (row: AcpmuxRow) => {
      const opening = this.events.find((event) => event.seq === row.seq);
      return opening ? compactionOf(sessionUpdate(opening))?.state : undefined;
    };
    const openRows = () =>
      this.rows
        .compactionRows()
        .filter(
          (row) => !held.has(row.id) && (row.compaction?.state === "running" || row.compaction?.inferred === true),
        );
    let continued = false;
    for (const next of [...held.values()]
      .filter((row) => row.kind === "compaction")
      .sort((a, b) => (a.seq ?? 0) - (b.seq ?? 0))) {
      const opened = openedAs(next);
      if (opened === undefined) continue;
      if (opened === "running") {
        if (continued) continue;
        continued = true;
        const onTime = openRows()
          .filter((row) => row.turnId === undefined || next.turnId === undefined || row.turnId === next.turnId)
          .filter((row) => next.at - (this.compactionHeardAt.get(row.id) ?? -Infinity) <= COMPACTION_REPEAT_WINDOW)
          .sort((a, b) => (b.seq ?? 0) - (a.seq ?? 0));
        const [into, ...rest] = onTime;
        for (const row of rest) this.rows.delete(row.id);
        // It goes on where that compaction started, as the whole record draws it, so a page
        // further back still finds the earliest note it was heard at.
        if (into?.compaction && next.compaction) {
          const joined: AcpmuxRow = {
            ...into,
            version: Math.max(into.version, next.version) + 1,
            compaction:
              next.compaction.state === "running" ? stillRunning(into.compaction, next.compaction) : next.compaction,
          };
          const heard = live.compactionHeardAt.get(next.id);
          live.compactionHeardAt.delete(next.id);
          if (heard !== undefined) live.compactionHeardAt.set(into.id, heard);
          this.rows.mergeChanges(next.id, into.id, this.rows.orderOf(next.id));
          held.delete(next.id);
          this.rows.delete(next.id);
          // The held events' row now: what they said of it stands.
          held.set(into.id, joined);
          this.rows.set(into.id, joined);
        }
        continue;
      }
      const open = openRows()
        .filter((row) => row.turnId === undefined || next.turnId === undefined || row.turnId === next.turnId)
        .sort((a, b) => (b.seq ?? 0) - (a.seq ?? 0))[0];
      if (!open || !next.compaction) continue;
      this.rows.set(open.id, { ...open, version: open.version + 1, compaction: next.compaction });
      this.rows.mergeChanges(next.id, open.id, this.rows.orderOf(next.id));
      held.delete(next.id);
      this.rows.delete(next.id);
    }
    // One still running that nothing continued never said how it ended: noted as failed, as the
    // next turn's start would.
    for (const row of openRows())
      if (row.compaction?.state === "running")
        this.rows.set(row.id, {
          ...row,
          version: row.version + 1,
          compaction: { ...row.compaction, state: "failed", inferred: true },
        });
    // A background shell the held events saw end while its call was not loaded ends on that call's
    // row now that this page brought it, and its own row goes.
    for (const row of held.values())
      if (row.backgroundTask && this.markBackgroundCall(row.backgroundTask, row.at, this.rows.orderOf(row.id))) {
        held.delete(row.id);
        this.rows.delete(row.id);
      }
    // A fork older than every held event is only in this page.
    const forkedAtSeq = live.forkedAtSeq ?? this.forkedAtSeq;
    // The folded page's rows answer for their own messages: a `?message=<id>` link to a message
    // from before this page keeps finding its row (links.ts). The held events' entries win, since
    // they are the live turn's.
    const messageRows = new Map([...this.messageRows, ...live.messageRows]);
    // History brings ended agents absent from the live fold; preserve their progress without
    // replacing newer live values. This reconciliation runs only when loading an older page.
    for (const agent of this.subagents.all()) {
      if (!live.subagents.progressSource.has(agent.id)) live.subagents.progressSource.updateAgent(agent);
    }
    // Progress stays the live chat's latest plan; an older page's only when the live events hold none,
    // and then as ended, since a later turn came after it.
    const progressRow = live.progressRow !== undefined ? live.progressRow : this.progressRow;
    const progressSuperseded =
      live.progressRow !== undefined ? live.progressSuperseded : this.progressRow !== undefined;
    Object.assign(this, live, {
      forkedAtSeq,
      messageRows,
      progressRow,
      progressSuperseded,
      toolRowScopes: new Map(live.toolRowScopes),
      currentToolScope: live.currentToolScope,
    });
    // A message id is stable across streamed chunks. Join only the boundary pair (the last older
    // fragment to the first held fragment), preserving deliberate cuts within either side.
    for (const [messageId, pageIds] of pageMessageRows) {
      const liveIds = live.messageRows.get(messageId) ?? [];
      const pageId = [...pageIds].reverse().find((rowId) => this.rows.get(rowId)?.kind === "assistant");
      const liveId = liveIds.find((rowId) => this.rows.get(rowId)?.kind === "assistant");
      if (!pageId || !liveId || pageId === liveId) continue;
      const pageRow = this.rows.get(pageId);
      const liveRow = this.rows.get(liveId);
      if (!pageRow?.text || !liveRow?.text || pageRow.at > liveRow.at) continue;
      this.rows.set(liveId, {
        ...liveRow,
        version: Math.max(pageRow.version, liveRow.version) + 1,
        text: `${pageRow.text}${liveRow.text}`,
      });
      this.rows.delete(pageId);
      this.messageRows.set(
        messageId,
        (this.messageRows.get(messageId) ?? []).filter((rowId) => rowId !== pageId),
      );
    }
    // Index retained tools once. Paging must reconcile O(page tools) rows, never scan all retained
    // rows for every item (a 20k-row chat otherwise makes one page quadratic).
    const heldTools = new Map<string, { rowId: string; tool: NonNullable<AcpmuxActivity["tool"]>; scope?: string }[]>();
    for (const row of held.values())
      for (const entry of row.items ?? [])
        if (entry.tool) {
          const key = `${entry.tool.id}\u0000${this.toolRowScopes.get(row.id) ?? ""}`;
          const list = heldTools.get(key) ?? [];
          list.push({ rowId: row.id, tool: entry.tool, scope: this.toolRowScopes.get(row.id) });
          heldTools.set(key, list);
        }
    for (const { callId, rowId, item, scope } of pageToolRows) {
      const liveRowId = live.toolRows.get(callId);
      const pageTool = item.tool;
      if (!pageTool) continue;
      const compatible = (left: typeof pageTool | undefined, right: typeof pageTool | undefined) =>
        left?.title === right?.title ||
        left?.title === callId ||
        right?.title === callId ||
        (left?.command !== undefined && left.command === right?.command);
      const scopeMatches = (candidateScope: string | undefined) =>
        scope === undefined || candidateScope === undefined || scope === candidateScope;
      const candidates = [
        ...(liveRowId
          ? [
              {
                rowId: liveRowId,
                row: this.rows.get(liveRowId),
                tool: this.rows.get(liveRowId)?.items?.find((entry) => entry.tool?.id === callId)?.tool,
                scope: live.toolRowScopes.get(liveRowId),
              },
            ]
          : []),
        ...(heldTools.get(`${callId}\u0000${scope ?? ""}`) ?? []),
        ...(scope === undefined
          ? [...heldTools.entries()]
              .filter(([key]) => key.startsWith(`${callId}\u0000`))
              .flatMap(([, entries]) => entries)
          : []),
      ];
      const seenCandidates = new Set<string>();
      const match = candidates
        // Every candidate's row as it stands now: held rows stay in `rows` through the fold.
        .map((candidate) => ({
          ...candidate,
          row: this.rows.get(candidate.rowId),
          key: `${candidate.rowId}\u0000${candidate.tool?.id ?? callId}`,
        }))
        .filter((candidate) => {
          if (seenCandidates.has(candidate.key)) return false;
          seenCandidates.add(candidate.key);
          return true;
        })
        .find(
          ({ rowId: candidateId, row: candidateRow, tool, scope: candidateScope }) =>
            candidateId !== rowId &&
            candidateRow !== undefined &&
            tool !== undefined &&
            candidateRow.at >= (this.rows.get(rowId)?.at ?? 0) &&
            scopeMatches(candidateScope) &&
            compatible(pageTool, tool),
        );
      if (match) {
        const pageRow = this.rows.get(rowId);
        if (pageRow?.items) {
          const remaining = pageRow.items.filter((entry) => entry !== item);
          if (remaining.length === 0) this.rows.delete(rowId);
          else
            this.rows.set(rowId, {
              ...pageRow,
              version: pageRow.version + 1,
              items: remaining,
              toolCount: remaining.filter((entry) => entry.kind === "tool").length,
            });
        }
        const retainedRow = this.rows.get(match.rowId);
        if (retainedRow?.items) {
          const retainedItems = retainedRow.items.map((entry) => {
            if (entry.tool?.id !== callId) return entry;
            return {
              ...entry,
              tool: {
                ...withAwaitingCall(entry.tool, false),
                title: entry.tool.title === callId ? pageTool.title : entry.tool.title,
                kind: entry.tool.kind ?? pageTool.kind,
                inputSummary: entry.tool.inputSummary ?? pageTool.inputSummary,
                command: entry.tool.command ?? pageTool.command,
                description: entry.tool.description ?? pageTool.description,
                locations: entry.tool.locations ?? pageTool.locations,
                startedAt: entry.tool.startedAt ?? pageTool.startedAt,
              },
            };
          });
          this.rows.set(match.rowId, { ...retainedRow, version: retainedRow.version + 1, items: retainedItems });
        }
        this.toolRows.set(callId, match.rowId);
        continue;
      }
      if (!this.toolRows.has(callId)) this.toolRows.set(callId, rowId);
      if (scope !== undefined) this.toolRowScopes.set(rowId, scope);
    }
    // Older turns end on their own result; a row of the live turn it closed (its typing row) stays.
    // A model change line the page moved back (`drawRunChanges` dropped it) stays gone.
    // A preset approval card the page merged into an older one stays gone.
    for (const [id, row] of held)
      if (
        !this.rows.has(id) &&
        !this.presetApprovalRemoved.has(id) &&
        (row.kind !== "sessionStart" || this.runChangeRows.has(id))
      )
        this.rows.set(id, row);
    this.presetApprovalRemoved.clear();
    // A held page can start at a prompt sent now whose cancel only this page holds: its row,
    // drawn before, goes on with that turn now, so the turn never reads as stopped.
    for (const event of this.events) {
      const promptId = event.kind === "user_message" ? event.msg?.promptId : undefined;
      if (typeof promptId !== "string" || !this.continuations.has(promptId)) continue;
      const row = this.rows.get(this.promptRowKeys.get(promptId) ?? `user-${event.seq}`);
      if (row && !row.continues) this.rows.set(row.id, { ...row, continues: true, version: row.version + 1 });
    }
  },
  /// The socket's own onclose ignores a socket close() already let go of, so settle requests here.
};

let installed = false;

export function installHistoryMethods(proto: object): void {
  if (installed) return;
  installed = true;
  for (const [name, method] of Object.entries(historyMethods)) {
    Object.defineProperty(proto, name, { configurable: true, writable: true, value: method });
  }
}
