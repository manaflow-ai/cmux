import type { AcpmuxBackgroundTurn, AcpmuxRow } from "../model";
import { rowFrameKey, SINCE_DIVIDER } from "../model";
import { BACKGROUND_TURN, backgroundTurnRowId } from "../conversation/backgroundTurns";
import { isVisiblyEmptyMessage } from "../conversation/visibleMessage";
import {
  markPullRequestActivityVersion,
  markPullRequestCommandVersion,
  markTranscriptSummaryVersion,
  pullRequestRowKey,
} from "../summary/transcriptPullRequests";
import { markOneRowChange } from "../rowChanges";
import { noteKeptPrefix } from "../conversation/prefixFlatMap";
import { RowUpdates } from "../rowUpdates";

/// More than one slot of the kept order changed, or it was rebuilt (`OrderedRows.changedSlot`).
const MANY_SLOTS = Symbol("many");

/// Whether two texts are one message at different completeness: one holds the other's opening or
/// ending whole (a repair read back chunks before or after it, or split a reply a lost call had
/// joined), 40 characters of it, and the shorter is at least half as long, so a short reply is never
/// taken for part of a long one, nor two replies for one by a common opening line. Linear in the longer; under 8 characters, only itself.
/// Takes texts already trimmed: ``adoptFrames`` trims each once, not once per pair.
function sameTrimmed(x: string, y: string): boolean {
  if (!x || !y) return false;
  if (x === y) return true;
  const [short, long] = x.length <= y.length ? [x, y] : [y, x];
  if (short.length < 8 || short.length * 2 < long.length) return false;
  const holds = (text: string, other: string) => text.includes(other.slice(0, 40)) || text.includes(other.slice(-40));
  return holds(long, short) || holds(short, long);
}

/// Transcript rows in the daemon's event order: each row keeps the sequence number of the event
/// that created it, so two wall clocks (or one millisecond) never put a prompt under its reply.
/// A row made without an event (a prompt sending or failed, a notice, the typing row) orders after
/// the events seen when it was made, so later turns go below it; after a lag rebuild, which
/// replays events older than it, it moves after them again.
export class OrderedRows extends Map<string, AcpmuxRow> {
  /// How many times any chat's rows were sorted whole (longChatCost.test.ts counts them per update).
  static sorts = 0;
  private readonly order = new Map<string, number>();
  /// No row's `order` is above this (a delete leaves it, a clear resets it): a background turn's
  /// started record at or past it claims no held row, so `openBackground` reads none of them.
  private highestOrder = Number.NEGATIVE_INFINITY;
  private putOrder(id: string, order: number): void {
    this.order.set(id, order);
    if (order > this.highestOrder) this.highestOrder = order;
  }
  /// The newest event that wrote each streamed reply (`assistant`), where it differs from the one
  /// that made it: a reply the person left mid-stream goes on past where they left (`placeAfter`).
  private readonly lastWrite = new Map<string, number>();
  private readonly local = new Set<string>();
  /// Where each row the pane made before any record of it (a prompt it sent) sorted when it was made:
  /// the place the person sent it at. A steer keeps it once its record comes (`keepSentPlace`), also
  /// when a rebuild makes its row again from that record. Kept past the row's delete for that rebuild;
  /// one number a prompt sent, gone with the chat (`clear`).
  private readonly sentPlaces = new Map<string, number>();
  private made = 0;
  /// The sequence number of the event being reduced.
  current: number | undefined;
  /// The newest event reduced so far.
  private latest = 0;
  /// The rows in order as of the last ``sorted()``, and each one's index there: a snapshot of a
  /// long chat whose rows only changed in place copies this instead of sorting every row again.
  private ordered: AcpmuxRow[] | undefined;
  private orderedIndex = new Map<string, number>();
  /// The array handed to snapshots. Metadata updates can emit without changing a transcript row;
  /// reuse this reference so the pane's derived rows stay memoized.
  private snapshot: AcpmuxRow[] | undefined;
  /// The one slot of `ordered` written in place since `snapshot` was made, when that is all that
  /// changed (MANY_SLOTS for any other change): the next snapshot says so (rowChanges.ts
  /// `markOneRowChange`), so the pane reads that row alone, not every row.
  private changedSlot: number | typeof MANY_SLOTS | undefined;
  /// The first slot of `ordered` any change since `snapshot` was made could have touched (MANY_SLOTS
  /// when the order was rebuilt or moved): the next snapshot says its rows before it are the last
  /// one's (prefixFlatMap.ts `noteKeptPrefix`), so every per-snapshot pass that reads only the rows
  /// after the kept prefix (markRows, sessionEdits, startedNames, prefixFlatMap) starts there with no
  /// walk over the chat. A tool call's start is a new slot at the end, its end a write in place.
  private firstChanged: number | typeof MANY_SLOTS | undefined;
  /// The last snapshot handed out, which the next one's change is from.
  private published: AcpmuxRow[] | undefined;
  private pullRequestActivityVersion = Symbol();
  private pullRequestCommandVersion = Symbol();
  private transcriptSummaryVersion = {};
  private readonly artifactUpdates = new RowUpdates((id) => this.get(id));
  /// The turns the agent ran on its own (acpmux `background_turn`): each one's started record's
  /// sequence number and its ended record's, once heard. A row an event between them made is that
  /// turn's (`inBackground`). An ended record heard first (an older page's started record comes
  /// later) waits in `backgroundEnds`.
  private backgroundSpans: { id: string; from: number; to?: number }[] = [];
  private readonly backgroundClaims = new Map<string, string[]>();
  private readonly backgroundEnds = new Map<string, { seq: number; turn: AcpmuxBackgroundTurn }>();
  /// Each background turn's reply rows, in order (`markBackgroundRows`).
  private readonly backgroundReplies = new Map<string, string[]>();

  /// What background turn `turn` replied, its messages' words in order; "" for none.
  backgroundReply(turn: string): string {
    const words: string[] = [];
    for (const id of this.backgroundReplies.get(turn) ?? []) {
      const row = this.get(id);
      if (row?.kind === "assistant" && row.inBackground === turn && !isVisiblyEmptyMessage(row))
        words.push(row.text!.trim());
    }
    return words.join("\n\n");
  }

  /// A background turn's started record at `seq`: how it ended when its ended record came first,
  /// and whether rows its events made before this record was heard draw something (`hasRows`).
  openBackground(id: string, seq: number): { ended?: AcpmuxBackgroundTurn; hasRows: boolean } {
    if (this.backgroundSpans.some((span) => span.id === id)) return { hasRows: false };
    const ended = this.backgroundEnds.get(id);
    this.backgroundSpans.push({ id, from: seq, to: ended?.seq });
    this.backgroundEnds.delete(id);
    let hasRows = false;
    const claimed: string[] = [];
    // A live start (no held row is newer than it) claims none: it reads no row of a long chat.
    if (seq >= this.highestOrder) return { ended: ended?.turn, hasRows };
    // An older page read later: rows its events made before this record was heard are the turn's too.
    for (const [rowId, order] of this.order) {
      if (this.local.has(rowId) || order <= seq || (ended !== undefined && order >= ended.seq)) continue;
      const row = this.get(rowId);
      if (!row || row.kind === BACKGROUND_TURN || row.kind === "user" || row.inBackground === id) continue;
      if (this.promptsReply(rowId, row, id)) continue;
      const tagged = { ...row, inBackground: id };
      claimed.push(rowId);
      if (!isVisiblyEmptyMessage(tagged)) hasRows = true;
      if (row.kind === "assistant") this.backgroundReplies.set(id, [...(this.backgroundReplies.get(id) ?? []), rowId]);
      super.set(rowId, tagged);
      const at = this.orderedIndex.get(rowId);
      if (this.ordered && at !== undefined) this.ordered[at] = tagged;
      this.snapshot = undefined;
      this.changedSlot = MANY_SLOTS;
      this.changedFrom(this.ordered && at !== undefined ? at : MANY_SLOTS);
      this.transcriptSummaryVersion = {};
    }
    if (!ended && claimed.length) this.backgroundClaims.set(id, claimed);
    return { ended: ended?.turn, hasRows };
  }

  /// A row of background turn `turn` that draws something: its line opens to it from now on. Its
  /// replies are kept by id (a few per turn), for the call its reaction goes onto.
  private markBackgroundRows(turn: string, row: AcpmuxRow): void {
    if (row.kind === "assistant") {
      const replies = this.backgroundReplies.get(turn);
      if (!replies) this.backgroundReplies.set(turn, [row.id]);
      else if (!replies.includes(row.id)) replies.push(row.id);
    }
    if (isVisiblyEmptyMessage(row)) return;
    const id = backgroundTurnRowId(turn);
    const line = this.get(id);
    if (!line?.background || line.background.hasRows) return;
    this.set(id, { ...line, version: line.version + 1, background: { ...line.background, hasRows: true } });
  }

  /// A background turn's ended record at `seq`, which says how it ended (`turn`).
  closeBackground(seq: number, turn: AcpmuxBackgroundTurn): void {
    const span = this.backgroundSpans.find((span) => span.id === turn.id);
    // A span a prompt already closed (`openBackgroundsBefore`) keeps that end: acpmux's own ended
    // record, heard later, says how the turn ended and never takes the prompt's rows back.
    if (span) span.to = span.to === undefined ? seq : Math.min(span.to, seq);
    else this.backgroundEnds.set(turn.id, { seq, turn });
    // An older page's start can arrive before its end while newer rows are already held.
    // The start attributed those rows provisionally; the end bounds that attribution.
    const claimed = this.backgroundClaims.get(turn.id) ?? [];
    this.backgroundClaims.delete(turn.id);
    for (const id of claimed) {
      const row = this.get(id);
      if (row?.inBackground !== turn.id || this.orderOf(id) < seq) continue;
      const { inBackground: _background, ...untagged } = row;
      const owner = this.backgroundAt(this.orderOf(id));
      const restored = owner === undefined ? untagged : { ...untagged, inBackground: owner };
      super.set(id, restored);
      const at = this.orderedIndex.get(id);
      if (this.ordered && at !== undefined) this.ordered[at] = restored;
      this.snapshot = undefined;
      this.changedSlot = MANY_SLOTS;
      this.changedFrom(this.ordered && at !== undefined ? at : MANY_SLOTS);
      this.transcriptSummaryVersion = {};
    }
    const replies = this.backgroundReplies.get(turn.id);
    if (replies)
      this.backgroundReplies.set(
        turn.id,
        replies.filter((id) => this.get(id)?.inBackground === turn.id),
      );
  }

  /// The background turns still open at `seq`: started before it, with no ended record heard.
  openBackgroundsBefore(seq: number): string[] {
    return this.backgroundSpans.filter((span) => span.to === undefined && span.from < seq).map((span) => span.id);
  }

  /// Whether a reply row is a prompt's turn's own, whatever span its event falls in: acpmux names a
  /// reply's row by its segment, which starts with the acpmux turn it was written in, or "-" for a
  /// turn the agent ran on its own (hub/stream.rs `before_agent_update`). A background finish's turn
  /// is an acpmux turn the pane brackets itself (bgDoneNotice.ts), so its replies stay its own.
  private promptsReply(id: string, row: AcpmuxRow, turn: string): boolean {
    if (row.kind !== "assistant" || turn.startsWith("bg-done-")) return false;
    const owner = /^assistant-([^.]+)\.[^.]+\.\d+$/.exec(id)?.[1];
    return owner !== undefined && owner !== "-";
  }

  /// The background turn an event at `order` belongs to.
  private backgroundAt(order: number): string | undefined {
    for (let at = this.backgroundSpans.length - 1; at >= 0; at -= 1) {
      const span = this.backgroundSpans[at]!;
      if (span.from < order && (span.to === undefined || order < span.to)) return span.id;
    }
    return undefined;
  }

  /// Puts back the earlier object of each row a rebuild made again unchanged (same kind, version and
  /// plain fields: a turn's totals change with what was folded before it, not its version), so what
  /// is keyed on the object (drawn heights, memoized rows, reused turns) survives the rebuild: paging
  /// older history in rebuilds every row. A background turn's line is compared whole: how it ended
  /// is in its `background`, and a line a prompt ended whose own result then arrived late has the
  /// same version either way (started, ended), so the earlier object kept "ended by a prompt".
  keepSame(previous: ReadonlyMap<string, AcpmuxRow>): void {
    const plainSame = (a: AcpmuxRow, b: AcpmuxRow) => {
      const keys = new Set([...Object.keys(a), ...Object.keys(b)]) as Set<keyof AcpmuxRow>;
      for (const key of keys) if (typeof a[key] !== "object" && a[key] !== b[key]) return false;
      return a.background === b.background || JSON.stringify(a.background) === JSON.stringify(b.background);
    };
    let changed = false;
    // Only the rows `previous` holds can be kept (a rebuild past a cut passes the refolded ones).
    for (const [id, old] of previous) {
      const row = this.get(id);
      if (!row || old === row || old.kind !== row.kind || old.version !== row.version || !plainSame(old, row)) continue;
      super.set(id, old);
      const at = this.orderedIndex.get(id);
      if (this.ordered && at !== undefined) this.ordered[at] = old;
      changed = true;
    }
    if (changed) {
      this.snapshot = undefined;
      this.changedSlot = MANY_SLOTS;
      this.firstChanged = MANY_SLOTS;
    }
  }

  /// The frame each message a rebuild made under a new id keeps drawing in (``adoptFrames``).
  private readonly frames = new Map<string, string>();
  /// The running turn's rows the open read, by id, with how many of their items it read: each row
  /// written carries it as `readAtOpen` (the client's `noteReadWork`). The client's, so a refold keeps it.
  readAtOpen: ReadonlyMap<string, number> | undefined;

  /// Writes `ids` again, so each carries `readAtOpen` as it is now.
  restampRead(ids: Iterable<string>): void {
    for (const id of ids) {
      const row = this.get(id);
      if (row) this.set(id, row, false);
    }
  }

  /// Keeps on screen, in the element it drew in, each prompt and reply a rebuild made again under a
  /// new id. A reply's id is the first of its chunks the pane held, so a turn repaired from its
  /// stored records after its first chunk was lost (`checkFinishedTurn`, a lag's reread), an older
  /// page or a reconnect's replay names it anew; as a new frame it unmounted and faded in again
  /// while the tool calls around it, keyed by their call ids, stayed (Leo, 2026-11-11: "it keeps
  /// showing and then hiding, and then showing and then hiding your responses, or my responses").
  /// Each message of a kind that went gives its frame to the new message of that kind whose words it
  /// holds or that holds its words, the nearest to it in length (an older page brings many new
  /// replies, and only the one it was cut from is it); that message's later updates keep the frame
  /// (``set``). Gone and new messages are few beside the chat: an older page's replies are new, but
  /// a page that names no shown message again leaves none gone, and returns at once.
  adoptFrames(previous: ReadonlyMap<string, AcpmuxRow>): void {
    const isMessage = (row: AcpmuxRow) => row.kind === "user" || row.kind === "assistant";
    const gone = [...previous.values()].filter((row) => isMessage(row) && !this.has(row.id));
    // Written outside any event: the row keeps its place and its last write.
    const current = this.current;
    this.current = undefined;
    // A frame whose own row came back (a fuller read named it as before) is that row's again: two
    // rows never draw in one frame.
    for (const [id, frame] of this.frames) {
      if (this.has(id) && !this.has(frame)) continue;
      this.frames.delete(id);
      const row = this.get(id);
      if (row?.frame === frame) this.set(id, { ...row, frame: undefined });
    }
    if (gone.length === 0) {
      this.current = current;
      return;
    }
    const fresh = [...this.values()].filter(
      (row) => isMessage(row) && row.frame === undefined && !previous.has(row.id),
    );
    // The frames rows draw in now. `previous` holds the rows shown before a reset too, which can name
    // a frame a row since took: a frame in use is never given again, so no two rows share one.
    const inUse = new Set<string>();
    for (const row of this.values()) inUse.add(rowFrameKey(row));
    // Each fresh text trimmed once; a pair whose lengths ``sameTrimmed`` refuses is passed over unread.
    const texts = fresh.map((row) => row.text?.trim() ?? "");
    for (const old of gone) {
      const frame = rowFrameKey(old);
      if (inUse.has(frame)) continue;
      const text = old.text?.trim() ?? "";
      const length = text.length;
      if (length === 0) continue;
      let best: AcpmuxRow | undefined;
      let bestLength = 0;
      // A tie goes to the newer row: the one a rebuild named anew is the newest of its copies.
      for (let at = 0; at < fresh.length; at += 1) {
        const row = fresh[at]!;
        const other = texts[at]!;
        const shorter = Math.min(length, other.length);
        if (
          row.kind !== old.kind ||
          (other.length !== length && (shorter < 8 || shorter * 2 < Math.max(length, other.length))) ||
          this.frames.has(row.id) ||
          !sameTrimmed(text, other) ||
          (best && Math.abs(other.length - length) > Math.abs(bestLength - length))
        )
          continue;
        best = row;
        bestLength = other.length;
      }
      if (!best) continue;
      inUse.add(frame);
      this.frames.set(best.id, frame);
      this.set(best.id, best);
    }
    this.current = current;
  }

  // Producers identify stream progress from the event, even when its row retains settled tools.
  override set(id: string, row: AcpmuxRow, summaryChanged = !row.streaming): this {
    const adopted = this.frames.get(id);
    if (adopted !== undefined && row.frame !== adopted) row = { ...row, frame: adopted };
    const read = this.readAtOpen?.get(id);
    if (row.readAtOpen !== read) {
      if (read === undefined) {
        const { readAtOpen: _read, ...rest } = row;
        row = rest;
      } else row = { ...row, readAtOpen: read };
    }
    const known = this.order.has(id);
    const previous = this.get(id);
    const unchanged = known && previous === row;
    if (!unchanged && pullRequestRowKey(previous) !== pullRequestRowKey(row))
      this.pullRequestActivityVersion = Symbol();
    if (!unchanged && row.kind === "activity" && pullRequestRowKey(previous) !== pullRequestRowKey(row))
      this.pullRequestCommandVersion = Symbol();
    if (!unchanged && (!known || summaryChanged)) this.transcriptSummaryVersion = {};
    if (!unchanged) this.snapshot = undefined;
    if (!known) {
      if (this.current !== undefined) {
        this.putOrder(id, this.current);
        this.latest = Math.max(this.latest, this.current);
      } else {
        const place = this.latest + 0.5 + (this.made += 1e-6);
        this.putOrder(id, place);
        this.local.add(id);
        if (!this.sentPlaces.has(id)) this.sentPlaces.set(id, place);
      }
    } else if (this.current !== undefined) {
      this.latest = Math.max(this.latest, this.current);
      if (row.kind === "assistant") this.lastWrite.set(id, this.current);
      if (!unchanged && this.current > (this.order.get(id) ?? Infinity)) this.noteChange(id, this.current);
    }
    // A row an event of a background turn made is that turn's, whoever updates it later. A prompt
    // never is: it starts a turn of its own (acpmux ends the background turn before it).
    let turn: string | undefined;
    if (this.backgroundSpans.length && row.kind !== BACKGROUND_TURN && row.kind !== "user" && !this.local.has(id)) {
      turn = this.backgroundAt(this.order.get(id)!);
      if (turn !== undefined && this.promptsReply(id, row, turn)) turn = undefined;
      if (turn !== undefined && row.inBackground !== turn) row = { ...row, inBackground: turn };
    }
    if (!known && this.prepending && (this.order.get(id) ?? Infinity) < this.prepending.below)
      this.prepending.made.push(id);
    if (this.ordered && !unchanged) this.keepOrdered(id, row, known);
    if (row.kind === "compaction") this.compactionIds.add(id);
    else if (previous?.kind === "compaction") this.compactionIds.delete(id);
    super.set(id, row);
    if (!unchanged) {
      this.artifactUpdates.note(row, this.current ?? this.order.get(id) ?? row.at);
      this.artifactUpdates.keepLive(this.size, () => this.values());
    }
    if (turn !== undefined) this.markBackgroundRows(turn, row);
    return this;
  }

  /// Updates the kept order for `row`: in its slot when only its content changed, at the end when it
  /// sorts after every row, otherwise ``sorted()`` sorts again.
  private keepOrdered(id: string, row: AcpmuxRow, known: boolean): void {
    const ordered = this.ordered!;
    const index = this.orderedIndex.get(id);
    // An older page's row while it folds (`beginPrepend`): it waits to be merged in, and the held
    // rows' order stands.
    const prepend = this.prepending;
    if (prepend && index === undefined && (this.order.get(id) ?? Infinity) < prepend.below) {
      if (!known) prepend.pending.push(id);
      this.changedSlot = MANY_SLOTS;
      this.firstChanged = MANY_SLOTS;
      return;
    }
    if (known && index !== undefined && (ordered[index]!.at === row.at || this.ownsSlot(index))) {
      ordered[index] = row;
      this.changedSlot = this.changedSlot === undefined || this.changedSlot === index ? index : MANY_SLOTS;
      this.changedFrom(index);
      return;
    }
    this.changedSlot = MANY_SLOTS;
    const last = ordered.at(-1);
    const order = this.order.get(id) ?? 0;
    const lastOrder = last ? (this.order.get(last.id) ?? 0) : -Infinity;
    if (!known && (order > lastOrder || (order === lastOrder && row.at >= last!.at))) {
      this.orderedIndex.set(id, ordered.length);
      this.changedFrom(ordered.length);
      ordered.push(row);
      return;
    }
    this.ordered = undefined;
    this.pullRequestActivityVersion = Symbol();
    this.pullRequestCommandVersion = Symbol();
    this.transcriptSummaryVersion = {};
  }

  /// Notes a change at slot `index` of the kept order (MANY_SLOTS: anywhere).
  private changedFrom(index: number | typeof MANY_SLOTS): void {
    const first = this.firstChanged;
    this.firstChanged =
      index === MANY_SLOTS || first === MANY_SLOTS ? MANY_SLOTS : first === undefined ? index : Math.min(first, index);
  }

  /// Whether the row at `index` of the kept order sorts by its event alone, so a change of its
  /// time (the tie-break, which a streamed delta moves) cannot move it.
  private ownsSlot(index: number): boolean {
    const ordered = this.ordered!;
    const order = this.order.get(ordered[index]!.id);
    const before = ordered[index - 1];
    const after = ordered[index + 1];
    return (!before || this.order.get(before.id) !== order) && (!after || this.order.get(after.id) !== order);
  }

  /// Moves `id` after every row the event being reduced made, and before the next event's: a steer
  /// its stopped turn never read goes below that turn's end (`deferLateSteers`).
  placeAfterCurrent(id: string): void {
    if (!this.has(id) || this.current === undefined) return;
    this.putOrder(id, this.current + 0.25);
    this.local.delete(id);
    this.pullRequestActivityVersion = Symbol();
    this.pullRequestCommandVersion = Symbol();
    this.transcriptSummaryVersion = {};
    this.ordered = undefined;
    this.snapshot = undefined;
  }

  /// Where "New since you looked" goes for a person who had seen through the event at `seq`: right
  /// after it, or before a reply that started at or before it and streamed on past it, so the rest
  /// of that reply reads as new. One pass over the rows, made only when the line is placed.
  placeAfter(seq: number): number {
    let place = seq + 0.5;
    for (const [id, last] of this.lastWrite) {
      const first = this.order.get(id);
      if (first !== undefined && first <= seq && last > seq) place = Math.min(place, first - 0.25);
    }
    return place;
  }

  /// The newest event that made or wrote row `id`. Rows made locally by the pane and the divider
  /// have no event to count as seen.
  seqOf(id: string): number | undefined {
    const first = this.order.get(id);
    if (first === undefined || this.local.has(id) || id === SINCE_DIVIDER) return undefined;
    return Math.max(Math.floor(first), this.lastWrite.get(id) ?? -1);
  }

  /// Counts agent turns written after a persisted seen cursor. A still-streaming reply counts as
  /// one turn so the return marker also covers a turn that has not ended yet.
  turnsAfter(seq: number): number {
    let turns = 0;
    let writing = false;
    for (const [id, row] of this) {
      const through = this.seqOf(id);
      if (through === undefined || through <= seq) continue;
      if (row.kind === "turnSummary") turns += 1;
      else if (row.kind === "assistant" || row.kind === "activity") writing = true;
    }
    return turns || (writing ? 1 : 0);
  }

  /// Sets `row` to sort at `place` (`placeAfter`): "New since you looked" (`SINCE_DIVIDER`), which no
  /// event of its own makes.
  setAt(place: number, row: AcpmuxRow): void {
    if (this.order.get(row.id) !== place) {
      this.putOrder(row.id, place);
      this.local.delete(row.id);
      this.ordered = undefined;
      this.transcriptSummaryVersion = {};
    } else if (this.ordered) {
      // Same place, new content (a recap arrived or was dismissed): its slot of the kept order too.
      const at = this.orderedIndex.get(row.id);
      if (at === undefined) this.ordered = undefined;
      else this.ordered[at] = row;
    }
    super.set(row.id, row);
    this.snapshot = undefined;
    this.changedSlot = MANY_SLOTS;
    this.firstChanged = MANY_SLOTS;
  }

  /// The place `id` sorts at: its event's sequence number, or just after the events seen before it.
  orderOf(id: string): number {
    return this.order.get(id) ?? Infinity;
  }

  /// Each write of a row by a later record than the one that made it, in record order: the
  /// record's seq and the row's id. Folding forward appends; a refold past a cut or an older page
  /// reads older records again and adds nothing (their writes are here already, or are older than
  /// any cut). A reply's chunks write its row one after another and take one entry.
  private changeSeqs: number[] = [];
  private changeIds: string[] = [];
  /// Where each changed row sorts (its maker's seq), kept here so a row a later record deleted
  /// still spans the records between.
  private changeOrders: number[] = [];

  private noteChange(id: string, seq: number, order = this.order.get(id) ?? Infinity): void {
    const last = this.changeSeqs.length - 1;
    if (last < 0 || seq >= this.changeSeqs[last]!) {
      if (last >= 0 && this.changeIds[last] === id && this.changeOrders[last] === order) this.changeSeqs[last] = seq;
      else {
        this.changeSeqs.push(seq);
        this.changeIds.push(id);
        this.changeOrders.push(order);
      }
      return;
    }
    // A write by an older record than the newest noted (a repair's record refolded past a cut, an
    // older page) goes in its place: a later cut between it and its row must still see it.
    const at = this.changesFrom(seq + 1);
    this.changeSeqs.splice(at, 0, seq);
    this.changeIds.splice(at, 0, id);
    this.changeOrders.splice(at, 0, order);
  }

  /// The index of the first change noted at or after record `seq`.
  private changesFrom(seq: number): number {
    let low = 0;
    let high = this.changeSeqs.length;
    while (low < high) {
      const middle = (low + high) >>> 1;
      if (this.changeSeqs[middle]! < seq) low = middle + 1;
      else high = middle;
    }
    return low;
  }

  /// A refold past a cut at `seq` writes every change from it on again: the ones noted go first,
  /// so the log does not grow with each repair.
  forgetChangesFrom(seq: number): void {
    const at = this.changesFrom(seq);
    this.changeSeqs.length = at;
    this.changeIds.length = at;
    this.changeOrders.length = at;
  }

  /// The oldest place of a row made before record `seq` that a record from `seq` on changed:
  /// a rebuild cut at `seq` would draw it again from only part of its records (direct.ts
  /// `rebuild`). Infinity when none. O(changes from `seq` on).
  spanningFrom(seq: number): number {
    let from = Infinity;
    for (let index = this.changeSeqs.length - 1; index >= 0 && this.changeSeqs[index]! >= seq; index -= 1) {
      const order = this.changeOrders[index]!;
      if (order < seq) from = Math.min(from, order);
    }
    return from;
  }

  /// The rows `spanningFrom` finds, each with its place: a shed that keeps some of them across its cut (direct.ts
  /// `shedOlderHeld`) moves the cut back only for the others. O(changes from `seq` on).
  spanningRows(seq: number): Map<string, number> {
    const rows = new Map<string, number>();
    for (let index = this.changeSeqs.length - 1; index >= 0 && this.changeSeqs[index]! >= seq; index -= 1) {
      const order = this.changeOrders[index]!;
      if (order < seq) rows.set(this.changeIds[index]!, order);
    }
    return rows;
  }

  /// A full rebuild folds every record again from the start, noting each change again.
  forgetChanges(): void {
    this.changeSeqs = [];
    this.changeIds = [];
    this.changeOrders = [];
  }

  /// Row `from`, made by record `made`, was merged into the older row `into` (an older page's fold
  /// joins a compaction's notes or a shell's end to rows it brought): `from`'s changes and the
  /// record that made it are `into`'s. Kept in record order; O(changes), on an older page only.
  mergeChanges(from: string, into: string, made: number): void {
    const order = this.order.get(into) ?? Infinity;
    for (let index = 0; index < this.changeIds.length; index += 1)
      if (this.changeIds[index] === from) {
        this.changeIds[index] = into;
        this.changeOrders[index] = order;
      }
    if (!Number.isFinite(made)) return;
    const at = this.changesFrom(made + 1);
    this.changeSeqs.splice(at, 0, made);
    this.changeIds.splice(at, 0, into);
    this.changeOrders.splice(at, 0, order);
  }

  /// An event was reduced (it may have made no row).
  saw(seq: number): void {
    this.latest = Math.max(this.latest, seq);
  }

  override delete(id: string): boolean {
    // Every text delta drops the typing row, which is usually gone already.
    if (!this.has(id)) return false;
    this.pullRequestActivityVersion = Symbol();
    this.pullRequestCommandVersion = Symbol();
    this.transcriptSummaryVersion = {};
    // A row a later record takes away changed too: a cut between them would draw it again.
    const made = this.order.get(id);
    if (this.current !== undefined && made !== undefined && made < this.current)
      this.noteChange(id, this.current, made);
    this.dropOrdered(id);
    this.snapshot = undefined;
    this.compactionIds.delete(id);
    this.order.delete(id);
    this.local.delete(id);
    this.lastWrite.delete(id);
    return super.delete(id);
  }

  override clear(): void {
    this.pullRequestActivityVersion = Symbol();
    this.pullRequestCommandVersion = Symbol();
    this.transcriptSummaryVersion = {};
    this.ordered = undefined;
    this.snapshot = undefined;
    this.order.clear();
    this.highestOrder = Number.NEGATIVE_INFINITY;
    this.local.clear();
    this.sentPlaces.clear();
    this.lastWrite.clear();
    this.frames.clear();
    this.latest = 0;
    this.backgroundSpans = [];
    this.backgroundClaims.clear();
    this.backgroundEnds.clear();
    this.compactionIds.clear();
    this.forgetChanges();
    super.clear();
  }

  /// Takes row `id` out of the kept order, so the next ``sorted()`` does not sort every row again
  /// (``retain`` gathers its deletes and mends the order once, from the oldest one).
  private dropOrdered(id: string): void {
    const ordered = this.ordered;
    if (!ordered) return;
    const at = this.orderedIndex.get(id);
    if (this.dropping) {
      if (at !== undefined) this.dropping.from = Math.min(this.dropping.from, at);
      return;
    }
    if (at === undefined) {
      // An older page's row not merged in yet: the merge leaves out what is gone.
      if (this.prepending && (this.order.get(id) ?? Infinity) < this.prepending.below) return;
      this.ordered = undefined;
      return;
    }
    // Out of its slot, the rows after it moving up one: O(rows after it), which for the rows a turn
    // drops (its typing row, a retry line) is the turn's few. Making the order again sorted every
    // row the chat held, once per turn live and once per turn of every rebuild.
    ordered.splice(at, 1);
    this.orderedIndex.delete(id);
    for (let index = at; index < ordered.length; index += 1) this.orderedIndex.set(ordered[index]!.id, index);
    this.changedSlot = MANY_SLOTS;
    // The rows from its slot on moved: the next snapshot keeps only the ones before it.
    this.changedFrom(at);
  }

  /// The oldest slot of the kept order a ``retain`` deleted, while it runs.
  private dropping: { from: number } | undefined;

  /// The compaction rows' ids: a turn's start and end settle the ones still running
  /// (`settleCompactions`), which walked every row the chat held, once per turn.
  private readonly compactionIds = new Set<string>();

  /// The compaction rows, in no particular order: O(compactions), not O(rows).
  compactionRows(): AcpmuxRow[] {
    const rows: AcpmuxRow[] = [];
    for (const id of this.compactionIds) {
      const row = this.get(id);
      if (row?.kind === "compaction") rows.push(row);
    }
    return rows;
  }

  /// Drops every row but those `keep` accepts; the event order starts over (a lag rebuild
  /// replays the events), and the rows kept go after the replayed events (``placeLocalLast()``).
  /// The kept order is mended from the oldest row dropped, so a rebuild that keeps the older rows
  /// as drawn (`rebuild`'s cut) costs the rows after the cut, not a sort of every row.
  retain(keep: (row: AcpmuxRow) => boolean): void {
    this.drop(this.values(), keep);
  }

  /// ``retain`` for the rows from event `seq` on and the rows made without an event: every older
  /// row stays, and only the rows read are paid for (`rebuild`'s cut).
  retainFrom(seq: number, keep: (row: AcpmuxRow) => boolean): void {
    const read = [...this.rowsFrom(seq)];
    for (const id of this.local) {
      const row = this.get(id);
      if (row && this.orderOf(id) < seq) read.push(row);
    }
    this.drop(read, keep);
  }

  /// The rows from event `seq` on, oldest first: a binary search of the kept order, O(rows returned).
  rowsFrom(seq: number): readonly AcpmuxRow[] {
    const ordered = this.inOrder();
    let low = 0;
    let high = ordered.length;
    while (low < high) {
      const middle = (low + high) >>> 1;
      if (this.orderOf(ordered[middle]!.id) < seq) low = middle + 1;
      else high = middle;
    }
    return ordered.slice(low);
  }

  /// Drops the rows made at `from` and up to `before` (records' seqs; either end open), but the ones `keep` accepts and
  /// the rows made without a record, with what the order and the change log kept of them, and the background turns
  /// that lie wholly between: the rows a run of held records at one end of the held window drew leave with them, in
  /// place (direct.ts `dropHeldRun`). Nothing is folded again and the rows left keep their objects and their order.
  /// The rows left after the run move up its length in the kept order (an index each); the rows dropped and the
  /// change log's entries for them cost O(what leaves). Returns the ids dropped.
  dropMade(from: number, before: number, keep: (row: AcpmuxRow) => boolean): Set<string> {
    this.inOrder();
    const ordered = this.ordered!;
    const firstAt = (seq: number) => {
      let low = 0;
      let high = ordered.length;
      while (low < high) {
        const middle = (low + high) >>> 1;
        if (this.orderOf(ordered[middle]!.id) < seq) low = middle + 1;
        else high = middle;
      }
      return low;
    };
    const start = from === -Infinity ? 0 : firstAt(from);
    const end = before === Infinity ? ordered.length : firstAt(before);
    const gone = new Set<string>();
    for (let index = start; index < end; index += 1) {
      const row = ordered[index]!;
      if (!this.local.has(row.id) && !keep(row)) gone.add(row.id);
    }
    if (gone.size > 0) {
      // Not a later record's change: no record is being reduced.
      const current = this.current;
      this.current = undefined;
      this.dropping = { from: Infinity };
      try {
        for (const id of gone) {
          this.frames.delete(id);
          this.delete(id);
        }
      } finally {
        this.current = current;
        this.dropping = undefined;
      }
      // The kept order closes over the run: one splice, the rows after it an index each.
      let write = start;
      for (let index = start; index < end; index += 1) {
        const row = ordered[index]!;
        if (gone.has(row.id)) this.orderedIndex.delete(row.id);
        else ordered[write++] = row;
      }
      if (write < end) {
        ordered.splice(write, end - write);
        for (let index = start; index < ordered.length; index += 1) this.orderedIndex.set(ordered[index]!.id, index);
      }
      this.snapshot = undefined;
      this.changedSlot = MANY_SLOTS;
      this.changedFrom(start);
    }
    // The change log: the writes the records that left made, one splice (it is in record order). The caller's run is
    // one no row spans, so no record kept wrote to a row that left.
    const low = from === -Infinity ? 0 : this.changesFrom(from);
    const high = before === Infinity ? this.changeSeqs.length : this.changesFrom(before);
    if (low < high) {
      this.changeSeqs.splice(low, high - low);
      this.changeIds.splice(low, high - low);
      this.changeOrders.splice(low, high - low);
    }
    // The background turns that began and ended in the run, and their replies.
    this.backgroundSpans = this.backgroundSpans.filter((span) => {
      const inside = span.from >= from && span.to !== undefined && span.to < before;
      if (inside) this.backgroundReplies.delete(span.id);
      return !inside;
    });
    for (const [id, end] of this.backgroundEnds)
      if (end.seq >= from && end.seq < before) this.backgroundEnds.delete(id);
    return gone;
  }

  private drop(rows: Iterable<AcpmuxRow>, keep: (row: AcpmuxRow) => boolean): void {
    this.dropping = { from: Infinity };
    // A Map visits the entries left after a delete, so deleting while iterating is safe.
    try {
      for (const row of rows) if (!keep(row)) this.delete(row.id);
    } finally {
      const from = this.dropping.from;
      this.dropping = undefined;
      const ordered = this.ordered;
      if (ordered && from !== Infinity) {
        const tail = ordered.slice(from).filter((row) => super.get(row.id) === row);
        for (const row of ordered.slice(from)) this.orderedIndex.delete(row.id);
        ordered.length = from;
        for (const row of tail) {
          this.orderedIndex.set(row.id, ordered.length);
          ordered.push(row);
        }
        this.changedSlot = MANY_SLOTS;
        this.changedFrom(from);
      }
    }
    this.latest = 0;
    // The replay hears the background turns' records again.
    this.backgroundSpans = [];
    this.backgroundClaims.clear();
    this.backgroundEnds.clear();
  }

  /// Moves the rows made without an event after every event, keeping their order: what a lag
  /// rebuild replayed happened before them.
  placeLocalLast(): void {
    this.pullRequestActivityVersion = Symbol();
    this.pullRequestCommandVersion = Symbol();
    this.transcriptSummaryVersion = {};
    // With no such rows the kept order stands.
    if (this.local.size > 0) this.ordered = undefined;
    this.snapshot = undefined;
    const local = [...this.local].sort((a, b) => (this.order.get(a) ?? 0) - (this.order.get(b) ?? 0));
    local.forEach((id, index) => {
      const after = this.latest + 0.5 + (index + 1) * 1e-6;
      // A steer still on its way keeps where it was sent, under the rows drawn then (`sentPlaces`);
      // a replay of fewer records (a seek back) puts it after them.
      const sent = this.get(id)?.delivery?.queued === true ? this.sentPlaces.get(id) : undefined;
      const place = sent !== undefined && sent < after ? sent : after;
      this.putOrder(id, this.withinTurn(id, place));
    });
  }

  /// A steer's row, now that its record (at the event being reduced) came: it keeps the place the
  /// person sent it at (`sentPlaces`), so every row that came in after the send stays under it and
  /// no row above it moves when its record lands (Leo, 2026-11-22: "THEN YOU SENT SHIT THEN MY STEER
  /// WENT UNDER IT"). The record's own place is where acpmux heard it, after whatever the agent wrote
  /// meanwhile; sorted there, the steer went down under rows drawn below it at the send. Only within
  /// the turn it went into: when a turn ended or a prompt opened one between the send and the record,
  /// the record's place stands. One look over the rows made since the send (a few).
  keepSentPlace(id: string): void {
    const row = this.get(id);
    const sent = this.sentPlaces.get(id);
    const now = this.order.get(id);
    if (!row?.steer || sent === undefined || now === undefined || sent >= now) return;
    for (const between of this.rowsFrom(sent)) {
      const order = this.order.get(between.id) ?? Infinity;
      if (order >= now) break;
      if (between.kind === "turnSummary" || (between.kind === "user" && !between.steer && !between.pending)) return;
    }
    this.putOrder(id, this.withinTurn(id, sent));
    this.ordered = undefined;
    this.snapshot = undefined;
  }

  /// An optimistic row has been accepted by an event: keep its id, but make the event its order.
  adoptEventOrder(id: string): void {
    if (!this.has(id)) return;
    this.local.delete(id);
    if (this.current !== undefined) {
      this.putOrder(id, this.withinTurn(id, this.current));
      this.latest = Math.max(this.latest, this.current);
    }
    this.ordered = undefined;
    this.snapshot = undefined;
  }

  /// Where a steer row may sort, given `place`: never after the end of the turn it went into. Its
  /// echo or a rebuild can come after that turn's summary (a busy daemon, a reconnect), and sorting
  /// it there drew the person's message under the agent's answer to it and opened the next turn
  /// with it (Leo, 2026-11-12: "in this case you didnt respond to me at all..."). It keeps the
  /// place it was sent at, or goes just before that summary.
  private withinTurn(id: string, place: number): number {
    const row = this.get(id);
    if (!row?.steer || !row.turnId) return place;
    const end = this.order.get(`summary-${row.turnId}`);
    if (end === undefined || place < end) return place;
    const sent = this.order.get(id);
    return sent !== undefined && sent < end ? sent : end - 0.5;
  }

  /// The rows in event order, as `sorted()` has them, without making a snapshot of them: a read of
  /// the newest rows walks back from the end, O(rows read), while the order is kept.
  inOrder(): readonly AcpmuxRow[] {
    if (this.ordered && this.prepending?.pending.length) this.mergePrepended();
    if (!this.ordered) {
      // A whole sort takes in a folding page's rows too: none waits to be merged again.
      if (this.prepending) this.prepending.pending = [];
      OrderedRows.sorts += 1;
      this.changedSlot = MANY_SLOTS;
      this.firstChanged = MANY_SLOTS;
      this.ordered = [...this.values()].sort(
        (a, b) => (this.order.get(a.id) ?? 0) - (this.order.get(b.id) ?? 0) || a.at - b.at,
      );
      this.orderedIndex = new Map(this.ordered.map((row, index) => [row.id, index]));
    }
    return this.ordered;
  }

  /// An older page folding in above every held row (`foldOlder`): the rows it makes, all ordered
  /// before `below`, wait in `pending` and are merged into the kept order once (`mergePrepended`), so
  /// the fold sorts the page's rows, not every row the chat holds. Each of the page's turn ends read
  /// the order back to its prompt (`turnTotals`), and every row the page made before it had thrown
  /// the kept order away: a page of 500 turns sorted the whole held chat 500 times, which on a 100k-row
  /// chat was most of an older page's 0.2-1.8 s (bench/transcript-scroll-up.bench.ts, FIXTURE=flat).
  /// `made` lists the page's rows in the order they were made (their records' order), for `turnTotals`.
  private prepending: { below: number; pending: string[]; made: string[] } | undefined;

  /// Starts an older page's fold above the rows ordered from `below` on (`prepending`).
  beginPrepend(below: number): void {
    this.inOrder();
    this.prepending = { below, pending: [], made: [] };
  }

  /// Ends the fold `beginPrepend` started: its rows go into the kept order.
  endPrepend(): void {
    if (this.ordered && this.prepending?.pending.length) this.mergePrepended();
    this.prepending = undefined;
  }

  /// The rows the folding page made, oldest first (`prepending`); undefined outside a fold.
  prependedRows(): readonly string[] | undefined {
    return this.prepending?.made;
  }

  /// Merges the folding page's rows into the kept order: a sort of the page's rows and one pass over
  /// the held ones, O(held + page log page) once a page, never a sort of every row.
  private mergePrepended(): void {
    const prepend = this.prepending!;
    const ordered = this.ordered!;
    const key = (row: AcpmuxRow) => this.order.get(row.id) ?? 0;
    const seen = new Set<string>();
    const page: AcpmuxRow[] = [];
    for (const id of prepend.pending) {
      if (seen.has(id)) continue;
      seen.add(id);
      const row = this.get(id);
      if (row) page.push(row);
    }
    prepend.pending = [];
    page.sort((a, b) => key(a) - key(b) || a.at - b.at);
    const merged: AcpmuxRow[] = [];
    let left = 0;
    let right = 0;
    while (left < page.length && right < ordered.length) {
      const a = page[left]!;
      const b = ordered[right]!;
      if (key(a) - key(b) < 0 || (key(a) === key(b) && a.at <= b.at)) merged.push(page[left++]!);
      else merged.push(ordered[right++]!);
    }
    while (left < page.length) merged.push(page[left++]!);
    while (right < ordered.length) merged.push(ordered[right++]!);
    this.ordered = merged;
    this.orderedIndex = new Map();
    for (let index = 0; index < merged.length; index += 1) this.orderedIndex.set(merged[index]!.id, index);
    this.changedSlot = MANY_SLOTS;
    this.firstChanged = MANY_SLOTS;
    this.snapshot = undefined;
  }

  /// The rows in event order (wall-clock time breaks a tie).
  sorted(): AcpmuxRow[] {
    const ordered = this.inOrder();
    if (!this.snapshot) {
      const from = this.published;
      this.snapshot = ordered.slice();
      if (typeof this.changedSlot === "number" && from && from.length === this.snapshot.length)
        markOneRowChange(this.snapshot, from, this.changedSlot);
      if (from && this.firstChanged !== MANY_SLOTS)
        noteKeptPrefix(this.snapshot, from, Math.min(this.firstChanged ?? Infinity, from.length, this.snapshot.length));
      this.published = this.snapshot;
      this.changedSlot = undefined;
      this.firstChanged = undefined;
      this.artifactUpdates.publish(this.snapshot);
      markPullRequestActivityVersion(this.snapshot, this.pullRequestActivityVersion);
      markPullRequestCommandVersion(this.snapshot, this.pullRequestCommandVersion);
      markTranscriptSummaryVersion(this.snapshot, this.transcriptSummaryVersion);
    }
    return this.snapshot;
  }
}
