// What a chat's last read left, so opening it again draws it on the frame the open lands instead
// of after acpmux's attach round trip (Leo 2026-10-20: a chat "should be instant if cached").
//
// The page keeps its own tails (`keptTails`), which is all a chat switch inside one pane needs.
// A chat opened in a NEW TAB lands on a new page, whose map starts empty, so the page also hands
// each tail to the app host (`chat.tail`) and asks it for one before it attaches
// (`chat.tail.get`). On a memory miss the host forwards the local daemon's bounded persisted
// peer snapshot, so restarting the app does not make a remote chat wait for its connection.
//
// A host that does not serve these ops (the page outside the app, the gallery, an older app) is no
// failure: the chat opens cold, as it did before.
import { peerCopyTail, type PeerCopy } from "./peerCopy";
import { postNative } from "./native";
import type { EventRecord } from "./direct";
import type { QueuedPrompt } from "./model";

/// A chat as the page last read it. What it says about the chat's *past* is drawn on the next
/// open; what it says about what the chat is *doing* is not (direct.ts `drawKeptTail`).
export type KeptTail = {
  /// Provenance of a persisted peer copy, retained until a live attach reconciles it.
  peerCopy?: PeerCopy;
  events: EventRecord[];
  summary: Record<string, any> | undefined;
  turnOpener: EventRecord | undefined;
  historyExhausted: boolean;
  queue: QueuedPrompt[];
  configSeq: number;
  usageFromSeq: number;
  /// A fork's tail drawn from the chat it forked (forkTail.ts): the seq it branched at, through
  /// which its attach checks these rows against acpmux's own page of the fork.
  forkedThrough?: number;
};

/// Chats whose tail is kept, and the events kept of each: the newest ones, as many as an attach
/// page holds, so a visit that paged older history in (megabytes of records) is not what the next
/// open keeps. A truncated tail is no longer a whole transcript, so the chat can load its older
/// history again.
const KEPT_TAILS = 20;
/// Chats read ahead (``rememberReadAhead``): the recent chats a person switches between and the ones
/// asked for ahead of a press (a hover, the host's `chat.prefetch`). A tier of their own, so reading
/// ahead never pushes a chat the reader opened out of ``keptTails``; a chat opened moves from this
/// tier to that one. Page memory only, but for a chat a sidebar hover rested on (`shareReadAhead`).
const READ_AHEAD_TAILS = 24;
export const KEPT_EVENTS = 400;
/// Most of a tail that crosses to the host, newest first. The page's own map holds the whole tail;
/// what the host keeps is bounded in bytes as well as in records, because one chat's 400 records
/// can be megabytes of pasted text. With the chat bound this is the whole of what the app holds:
/// at most ``KEPT_TAILS`` chats of this, about 5 MiB, for every tab at once. A chat whose newest
/// record alone is larger hands over nothing, rather than make the bound a chat's paste wide; it
/// opens cold in the next tab, as it did before.
const HOST_TAIL_BYTES = 256 * 1024;
/// The longest an open waits on the host for a tail. The host answers in process and in memory, so
/// this is only there so a host that does not answer at all cannot hold a chat up — the same
/// reason `SCROLL_ANCHOR_READ_MS` exists for the reading place (App.tsx).
const HOST_TAIL_READ_MS = 250;

const keptTails = new Map<string, KeptTail>();
/// Tails read ahead, least recently read first; handed to the host only for a hover (`shareReadAhead`).
const readAheadTails = new Map<string, KeptTail>();
/// One host read per chat at a time, so a prefetch and the read that awaits it are one round trip.
const reading = new Map<string, Promise<KeptTail | undefined>>();
/// How far this page has shown each chat: the newest record of the last tail a client of the page
/// kept of it (what it had on screen then), and the chat's generation (its `createdAt`). A copy older than this is never
/// drawn again (`olderThanShown`): one source wins, so a reconnect cannot put a saved copy back over
/// the live chat the reader already saw (Leo, 2026-11-12: the chat flipped between "49 stopped" and
/// an old "32 stopped" on every reconnect). Bounded as the tails are, so a chat whose tails both
/// copies let go of opens on whatever copy is left (an offline machine's Mac copy) rather than blank.
const shownThrough = new Map<string, { through: number; generation: unknown }>();
const SHOWN_CHATS = KEPT_TAILS;

/// The newest record a tail draws: its newest event, or how far its Mac's copy covers.
function tailThrough(tail: KeptTail): number {
  return Math.max(tail.events.at(-1)?.seq ?? 0, tail.peerCopy?.lastSeq ?? 0);
}

/// A client's own tail is what it had on screen, so it sets the mark even below an older one: a
/// journal that went backwards (a hard-stopped machine) is read again as acpmux holds it now.
function noteShown(sessionId: string, tail: KeptTail): void {
  shownThrough.delete(sessionId);
  shownThrough.set(sessionId, { through: tailThrough(tail), generation: tail.summary?.createdAt });
  while (shownThrough.size > SHOWN_CHATS) shownThrough.delete(shownThrough.keys().next().value!);
}

/// True when `tail` is older than what this page already showed of the chat, so drawing it would
/// take the reader back (direct.ts `drawKeptTail` refuses it and the open waits for acpmux, whose
/// attach is the newest there is). A tail of another generation of the chat is not compared.
export function olderThanShown(sessionId: string, tail: KeptTail): boolean {
  const held = shownThrough.get(sessionId);
  if (!held || held.generation !== tail.summary?.createdAt) return false;
  return tailThrough(tail) < held.through;
}

/// The tail this page holds for `sessionId`, if it read the chat already or took it from the host.
export function keptTail(sessionId: string): KeptTail | undefined {
  return keptTails.get(sessionId) ?? readAheadTails.get(sessionId);
}

/// Keeps a tail read ahead of any open of the chat, in this page only. A chat this page read itself
/// keeps that tail, which is the newer one.
export function rememberReadAhead(sessionId: string, tail: KeptTail): void {
  if (keptTails.has(sessionId)) return;
  readAheadTails.delete(sessionId);
  readAheadTails.set(sessionId, tail);
  while (readAheadTails.size > READ_AHEAD_TAILS) readAheadTails.delete(readAheadTails.keys().next().value!);
}

/// Hands this page's tail of `sessionId` to the app host, for a chat a rested sidebar hover says is
/// likely next (hoverPrefetch.ts): the click opens it in another tab, on a new page, which draws
/// what the host holds (`readHostTail`) before its attach answers. The one read-ahead tier tail that
/// crosses to the host: a hover is a guess a person made, where the recent-chats pass is the page's
/// own. Bounded as every hand-over is (`writeHostTail`), and by the host's 20 chats. False when the
/// page holds no tail of the chat.
///
/// Never older than what the host holds: another tab may have handed the host a newer or fuller
/// read of the chat, and a hover must not put an older transcript in its place (the next tab would
/// draw fewer messages until its attach answered). So the write is `ifNewer`: the host compares and
/// keeps in one step (AgentPaneTailCache `rememberIfNewer`), keeping its own on a tie, and a page
/// can never race another page's write between a read and its own.
export function shareReadAhead(sessionId: string): boolean {
  const tail = keptTail(sessionId);
  if (!tail) return false;
  writeHostTail(sessionId, tail, true);
  return true;
}

/// Keeps `tail` for this chat's next open, here and in the app host.
///
/// `forThisPage` is false when the client that read the chat is going away (its `close`, the
/// page's `pagehide`): the host's copy is the one that outlives the page, so the map gains no new
/// chat behind a client that no longer exists (it refreshes one it holds already, below).
///
/// With a host this costs the next client in that page one in-process read instead of a map hit,
/// and what it reads back is at most what the map held: `writeHostTail`'s byte bound may have cut
/// the tail, so the chat draws fewer rows (with its older turns still loadable), and the host's
/// chat cap is shared by every page where `KEPT_TAILS` is per page, so the copy can be gone and the
/// chat opens cold. Each of those is a colder draw of the same chat, which is the trade. It matters
/// where there is no host to read back from — a page outside the app, the gallery, a test — and
/// where `writeHostTail` cut the tail to nothing: there the map would be the only copy, and a later
/// client would draw a chat it never attached to as though it had. Session ids are not reused, so
/// the rows would be that chat's; they would simply be rows this client never read and cannot stand
/// behind, which is the same thing `forgetTail` exists to prevent after a failed attach.
///
/// A client going away still replaces a tail this page already holds of the chat: that tail is
/// older than this one, and the client the pane makes next on a lost connection draws the map's
/// tail while it connects (direct.ts `drawTailWhileConnecting`). Left behind, it drew the chat as
/// it was when it was last left, then the attach drew it as it is, once per dropped connection.
export function rememberTail(sessionId: string, tail: KeptTail, forThisPage = true): void {
  noteShown(sessionId, tail);
  if (!forThisPage && readAheadTails.has(sessionId)) readAheadTails.set(sessionId, tail);
  if (forThisPage || keptTails.has(sessionId)) {
    readAheadTails.delete(sessionId);
    keptTails.delete(sessionId);
    keptTails.set(sessionId, tail);
    while (keptTails.size > KEPT_TAILS) keptTails.delete(keptTails.keys().next().value!);
  }
  writeHostTail(sessionId, tail);
}

/// A chat whose transcript this page no longer stands behind (acpmux purged it, or an attach of it
/// failed): its next open reads acpmux again, in this tab and in the next one.
export function forgetTail(sessionId: string): void {
  keptTails.delete(sessionId);
  shownThrough.delete(sessionId);
  readAheadTails.delete(sessionId);
  reading.delete(sessionId);
  void callHost("chat.tail", { sessionId }).catch(() => undefined);
  // Its drawn copy (chatSnapshot/) goes with it: the next launch draws no frame of it either. When
  // it went (`savedAt`): a copy captured before it and arriving after is never kept.
  void callHost("chat.snapshot.put", { sessionId, savedAt: Date.now() }).catch(() => undefined);
}

/// Asks the app host for this chat's tail and keeps what it answers, so a cold page can draw the
/// chat another tab read. Answers the tail, or undefined when there is none (and when the page
/// runs outside the app, where there is no host to ask).
///
/// A cache is never allowed to hold up an open, so the read is raced against HOST_TAIL_READ_MS:
/// a host that does not answer costs the chat nothing and the attach goes on without a tail, as
/// `chat.scrollAnchor.get` does for the reading place. A late answer is still kept, for the next
/// chat that asks.
export function readHostTail(sessionId: string): Promise<KeptTail | undefined> {
  const read = startHostRead(sessionId);
  return Promise.race([
    read,
    new Promise<undefined>((resolve) => setTimeout(() => resolve(undefined), HOST_TAIL_READ_MS)),
  ]);
}

/// Keeps the tail the app host handed this page with an adopt event (AgentPaneView+SessionAdopt.swift):
/// the tail `chat.tail.get` would answer, read the same way, without its round trip, so the adopted
/// page draws the chat in the event's own turn. A page that read the chat itself keeps its own, newer
/// tail. True when it kept the handed one.
export function keepHandedTail(sessionId: string, value: unknown): boolean {
  if (keptTails.has(sessionId)) return false;
  const tail = tailFromHost(value);
  if (!tail) return false;
  readAheadTails.delete(sessionId);
  keptTails.set(sessionId, tail);
  while (keptTails.size > KEPT_TAILS) keptTails.delete(keptTails.keys().next().value!);
  return true;
}

function startHostRead(sessionId: string): Promise<KeptTail | undefined> {
  const already = reading.get(sessionId);
  if (already) return already;
  const read: Promise<KeptTail | undefined> = callHost<unknown>("chat.tail.get", { sessionId })
    .then((value) => {
      const envelope = value as { stale?: unknown; sessionId?: unknown; qualifiedSessionId?: unknown } | null;
      const snapshot = envelope?.stale === true;
      const named = envelope?.sessionId === sessionId || envelope?.qualifiedSessionId === sessionId;
      const copy = snapshot && named ? peerCopyTail(value, sessionId) : undefined;
      const tail = snapshot ? copy?.tail : tailFromHost(value);
      // Only when this page read nothing of its own meanwhile (its own tail is the newer one) and
      // only while this read is still the chat's: `forgetTail` drops the entry for a chat this page
      // no longer stands behind, and an answer already in flight must not put it back.
      if (tail && !keptTails.has(sessionId) && reading.get(sessionId) === read) {
        keptTails.set(sessionId, tail);
        while (keptTails.size > KEPT_TAILS) keptTails.delete(keptTails.keys().next().value!);
      }
      return tail;
    })
    // A host without these ops, no host at all (the gallery, a test page), or a host that refuses:
    // the chat has no kept tail and opens from acpmux, as it did before. A cache never fails an open.
    .catch(() => undefined)
    .finally(() => {
      // Only this read's own entry: a `forgetTail` and a second read since would otherwise lose
      // theirs to a late answer's cleanup.
      if (reading.get(sessionId) === read) reading.delete(sessionId);
    });
  reading.set(sessionId, read);
  return read;
}

/// The host, through the seam the pane's other host calls go through (App.tsx `callNative`): the
/// actions a test or automation harness installed, else the app host itself.
function callHost<T>(method: string, params: Record<string, unknown>): Promise<T> {
  // The client also runs with no page around it (its own tests, tools): no window is no host, and
  // every caller here takes a refusal as "no tail kept".
  // l10n-allow: nobody reads it — every caller here catches and goes on without a tail.
  if (typeof window === "undefined") return Promise.reject(new Error("the agent pane has no page"));
  const direct = window.cmuxAcpmuxActions?.[method];
  if (direct) return direct(params) as Promise<T>;
  return postNative<T>(method, params);
}

/// Hands the tail to the host for the next tab, bounded in records and bytes. Never awaited: an
/// open must not wait on it, and a host that refuses it only means the next tab opens cold.
/// `ifNewer` (a hover's hand-over, ``shareReadAhead``): the host keeps it only over an older tail,
/// and a tail cut to nothing forgets nothing.
function writeHostTail(sessionId: string, tail: KeptTail, ifNewer = false): void {
  // The rest of the tail is counted first, because it is not bounded by a record count the way
  // `events` is: `queue` carries the whole text of every queued prompt, and a reader who queued a
  // pasted log would otherwise hand over megabytes that neither side counts.
  const rest = { ...tail, events: [] as EventRecord[] };
  // Each message's streamed chunks as one record (`packStreamed`): the host bounds a tail at
  // ``KEPT_EVENTS`` records, which `keptEvents` counts this way.
  const packed = packStreamed(tail.events);
  const events = newestWithin(packed, Math.max(0, HOST_TAIL_BYTES - bytesOf(rest)));
  // Not one record of this chat fits the host's bound (a single huge paste, or a queue that fills
  // it on its own): the host forgets what it had rather than keeping an older tail under a chat
  // this page has since read on.
  if (events.length === 0) {
    if (!ifNewer) void callHost("chat.tail", { sessionId }).catch(() => undefined);
    return;
  }
  void callHost("chat.tail", {
    sessionId,
    ...(ifNewer ? { ifNewer: true } : {}),
    tail: {
      ...tail,
      events,
      // Only a whole transcript is exhausted: a tail the byte bound cut has older events to read,
      // and a tail that claimed otherwise would hide them (test/reopened-chat-history.test.ts).
      historyExhausted: tail.historyExhausted && events.length === packed.length,
    },
  }).catch(() => undefined);
}

/// What `value` costs the host, measured the one way both bounds are measured: its JSON's length.
function bytesOf(value: unknown): number {
  return JSON.stringify(value)?.length ?? 0;
}

/// The newest records of `events` whose JSON fits `maxBytes`; none when even the newest does not.
function newestWithin(events: EventRecord[], maxBytes: number): EventRecord[] {
  const kept: EventRecord[] = [];
  let bytes = 0;
  for (let at = events.length - 1; at >= 0; at -= 1) {
    const event = events[at]!;
    bytes += JSON.stringify(event).length;
    if (bytes > maxBytes) break;
    kept.unshift(event);
  }
  return kept;
}

/// Kinds an agent streams a few words per record (acpmux journals each chunk): a working chat's
/// records are mostly these, thinking above all (5,906 of one Claude chat's 8,300 transcript
/// records, beside 227 tool calls).
const STREAMED_KINDS = new Set(["agent_message_chunk", "agent_thought_chunk"]);

/// The newest records of `events` a tail keeps: the newest ``KEPT_EVENTS`` messages, each run of
/// one message's streamed chunks counted once, so the tail holds the chat's last turns as they
/// read, not the last few hundred fragments of one. A run is never cut: the tail starts where one
/// starts. The records are the page's own, unchanged; only the hand-over to the host packs each
/// run into one record (`packStreamed`), which is what keeps the host's bound at ``KEPT_EVENTS``.
export function keptEvents(events: EventRecord[]): EventRecord[] {
  let count = 0;
  let start = events.length;
  let newerKey: string | undefined;
  for (let at = events.length - 1; at >= 0; at -= 1) {
    const key = streamedRun(events[at]!);
    if (key === undefined || key !== newerKey) {
      if (count === KEPT_EVENTS) break;
      count += 1;
    }
    start = at;
    newerKey = key;
  }
  return events.slice(start);
}

/// One run's chunks, packed: each chunk's seq, time and text length, in order.
type PackedChunk = [seq: number, at: number, length: number];
type PackedRecord = EventRecord & { chunks?: PackedChunk[] };

/// `events` with each run of one message's streamed chunks as one record, for the host's copy: the
/// run's text joined, its last chunk's `seq` and `at` (the host keeps the tail with the newest
/// `seq`, AgentPaneTailCache `newestSeq`), and `chunks`, from which `unpackStreamed` gives back
/// every chunk as it was. Lossless: a page reads back exactly the records it handed over.
export function packStreamed(events: EventRecord[]): EventRecord[] {
  const out: EventRecord[] = [];
  let run: EventRecord[] = [];
  let runKey: string | undefined;
  const close = () => {
    if (run.length === 1) out.push(run[0]!);
    else if (run.length > 1) {
      const first = run[0]!;
      const last = run.at(-1)!;
      const update = first.msg.params.update;
      const texts = run.map((event) => event.msg.params.update.content.text as string);
      const packed: PackedRecord = {
        ...first,
        seq: last.seq,
        at: last.at,
        msg: {
          ...first.msg,
          params: { ...first.msg.params, update: { ...update, content: { ...update.content, text: texts.join("") } } },
        },
        chunks: run.map((event, index) => [event.seq, event.at, texts[index]!.length]),
      };
      out.push(packed);
    }
    run = [];
  };
  for (const event of events) {
    const key = streamedRun(event);
    if (key === undefined || key !== runKey) close();
    runKey = key;
    if (key === undefined) out.push(event);
    else run.push(event);
  }
  close();
  return out;
}

/// The records `packStreamed` packed, each run's chunks given back as they were. A packed record
/// whose chunks do not add up to its text is dropped: the chat opens without that message until
/// its attach reads it, as when a chunk was missed live.
export function unpackStreamed(events: EventRecord[]): EventRecord[] {
  const out: EventRecord[] = [];
  for (const event of events as PackedRecord[]) {
    const { chunks, ...record } = event;
    if (chunks === undefined) {
      out.push(event);
      continue;
    }
    const text = record.msg?.params?.update?.content?.text;
    const valid =
      Array.isArray(chunks) &&
      typeof text === "string" &&
      chunks.every(
        (chunk) =>
          Array.isArray(chunk) &&
          typeof chunk[0] === "number" &&
          typeof chunk[1] === "number" &&
          typeof chunk[2] === "number" &&
          chunk[2] >= 0,
      ) &&
      chunks.reduce((sum, chunk) => sum + chunk[2], 0) === text.length;
    if (!valid) continue;
    let from = 0;
    for (const [seq, at, length] of chunks) {
      const update = record.msg.params.update;
      out.push({
        ...record,
        seq,
        at,
        msg: {
          ...record.msg,
          params: {
            ...record.msg.params,
            update: { ...update, content: { ...update.content, text: text.slice(from, from + length) } },
          },
        },
      });
      from += length;
    }
  }
  return out;
}

/// What a streamed chunk shares with the rest of its message's chunks (everything but its seq,
/// time and text), or undefined for a record that is no streamed text.
function streamedRun(event: EventRecord): string | undefined {
  if (!STREAMED_KINDS.has(event.kind)) return undefined;
  const update = event.msg?.params?.update;
  const content = update?.content;
  if (content?.type !== "text" || typeof content.text !== "string") return undefined;
  const { seq: _seq, at: _at, msg, ...rest } = event;
  return JSON.stringify([
    rest,
    { ...msg, params: { ...msg.params, update: { ...update, content: { ...content, text: "" } } } },
  ]);
}

/// The host's answer as a tail, or undefined when it holds none or answers something else. Only
/// the shape the page wrote is read back; anything missing leaves the chat to open cold.
function tailFromHost(value: unknown): KeptTail | undefined {
  const tail = (value ?? undefined) as Partial<KeptTail> | undefined;
  if (!tail || typeof tail !== "object") return undefined;
  const listed = Array.isArray(tail.events) ? tail.events : [];
  const packed = listed.filter(isEventRecord);
  // Each packed message back as the chunks the page handed over (`packStreamed`).
  const events = unpackStreamed(packed.slice(-KEPT_EVENTS));
  if (events.length === 0) return undefined;
  return {
    events,
    summary: typeof tail.summary === "object" && tail.summary !== null ? tail.summary : undefined,
    turnOpener: isEventRecord(tail.turnOpener) ? tail.turnOpener : undefined,
    // Only a whole tail can call the chat's history read through: a record dropped here (or by the
    // cap) leaves a hole or a cut, and a cut that claimed otherwise would hide the chat's older
    // turns, which is #23064's bug.
    historyExhausted:
      tail.historyExhausted === true &&
      packed.length === listed.length &&
      packed.length <= KEPT_EVENTS &&
      events.length === packed.reduce((count, event) => count + ((event as PackedRecord).chunks?.length ?? 1), 0),
    queue: Array.isArray(tail.queue) ? (tail.queue as QueuedPrompt[]) : [],
    configSeq: typeof tail.configSeq === "number" ? tail.configSeq : 0,
    usageFromSeq: typeof tail.usageFromSeq === "number" ? tail.usageFromSeq : 0,
    ...(typeof tail.forkedThrough === "number" ? { forkedThrough: tail.forkedThrough } : {}),
  };
}

function isEventRecord(value: unknown): value is EventRecord {
  const event = value as EventRecord | undefined;
  return (
    typeof event === "object" &&
    event !== null &&
    typeof event.seq === "number" &&
    typeof event.kind === "string" &&
    typeof event.msg === "object" &&
    event.msg !== null
  );
}

/// Test seam: a fresh page, holding no tails of its own (the host keeps its own).
export function resetKeptTailsForTests(): void {
  keptTails.clear();
  readAheadTails.clear();
  reading.clear();
  shownThrough.clear();
}
