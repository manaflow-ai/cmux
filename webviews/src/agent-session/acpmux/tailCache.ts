// What a chat's last read left, so opening it again draws it on the frame the open lands instead
// of after acpmux's attach round trip (Leo 2026-10-20: a chat "should be instant if cached").
//
// The page keeps its own tails (`keptTails`), which is all a chat switch inside one pane needs.
// A chat opened in a NEW TAB lands on a new page, whose map starts empty, so the page also hands
// each tail to the app host (`chat.tail`) and asks it for one before it attaches
// (`chat.tail.get`). The host holds them IN MEMORY ONLY: nothing is written to disk, so there is
// no new place a transcript persists, and quitting the app forgets them (AgentPaneTailCache.swift).
//
// A host that does not serve these ops (the page outside the app, the gallery, an older app) is no
// failure: the chat opens cold, as it did before.
import { postNative } from "./native";
import type { EventRecord } from "./direct";
import type { QueuedPrompt } from "./model";

/// A chat as the page last read it. What it says about the chat's *past* is drawn on the next
/// open; what it says about what the chat is *doing* is not (direct.ts `drawKeptTail`).
export type KeptTail = {
  events: EventRecord[];
  summary: Record<string, any> | undefined;
  turnOpener: EventRecord | undefined;
  historyExhausted: boolean;
  queue: QueuedPrompt[];
  configSeq: number;
  usageFromSeq: number;
};

/// Chats whose tail is kept, and the events kept of each: the newest ones, as many as an attach
/// page holds, so a visit that paged older history in (megabytes of records) is not what the next
/// open keeps. A truncated tail is no longer a whole transcript, so the chat can load its older
/// history again.
const KEPT_TAILS = 8;
export const KEPT_EVENTS = 400;
/// Most of a tail that crosses to the host, newest first. The page's own map holds the whole tail;
/// what the host keeps is bounded in bytes as well as in records, because one chat's 400 records
/// can be megabytes of pasted text. With the chat bound this is the whole of what the app holds:
/// at most ``KEPT_TAILS`` chats of this, about 2 MiB, for every tab at once. A chat whose newest
/// record alone is larger hands over nothing, rather than make the bound a chat's paste wide; it
/// opens cold in the next tab, as it did before.
const HOST_TAIL_BYTES = 256 * 1024;

const keptTails = new Map<string, KeptTail>();
/// One host read per chat at a time, so a prefetch and the read that awaits it are one round trip.
const reading = new Map<string, Promise<KeptTail | undefined>>();

/// The tail this page holds for `sessionId`, if it read the chat already or took it from the host.
export function keptTail(sessionId: string): KeptTail | undefined {
  return keptTails.get(sessionId);
}

/// Keeps `tail` for this chat's next open, here and in the app host.
export function rememberTail(sessionId: string, tail: KeptTail): void {
  keptTails.delete(sessionId);
  keptTails.set(sessionId, tail);
  while (keptTails.size > KEPT_TAILS) keptTails.delete(keptTails.keys().next().value!);
  writeHostTail(sessionId, tail);
}

/// A chat whose transcript this page no longer stands behind (acpmux purged it, or an attach of it
/// failed): its next open reads acpmux again, in this tab and in the next one.
export function forgetTail(sessionId: string): void {
  keptTails.delete(sessionId);
  reading.delete(sessionId);
  void callHost("chat.tail", { sessionId }).catch(() => undefined);
}

/// Asks the app host for this chat's tail and keeps what it answers, so a cold page can draw the
/// chat another tab read. Answers the tail, or undefined when there is none (and when the page
/// runs outside the app, where there is no host to ask).
export function readHostTail(sessionId: string): Promise<KeptTail | undefined> {
  const already = reading.get(sessionId);
  if (already) return already;
  const read = callHost<unknown>("chat.tail.get", { sessionId })
    .then((value) => {
      const tail = tailFromHost(value);
      // Only when this page read nothing of its own meanwhile: its own tail is the newer one.
      if (tail && !keptTails.has(sessionId)) {
        keptTails.set(sessionId, tail);
        while (keptTails.size > KEPT_TAILS) keptTails.delete(keptTails.keys().next().value!);
      }
      return tail;
    })
    // A host without these ops, no host at all (the gallery, a test page), or a host that refuses:
    // the chat has no kept tail and opens from acpmux, as it did before. A cache never fails an open.
    .catch(() => undefined)
    .finally(() => {
      reading.delete(sessionId);
    });
  reading.set(sessionId, read);
  return read;
}

/// The host, through the seam the pane's other host calls go through (App.tsx `callNative`): the
/// actions a test or automation harness installed, else the app host itself.
function callHost<T>(method: string, params: Record<string, unknown>): Promise<T> {
  // The client also runs with no page around it (its own tests, tools): no window is no host, and
  // every caller here takes a refusal as "no tail kept".
  if (typeof window === "undefined") return Promise.reject(new Error("the agent pane has no page"));
  const direct = window.cmuxAcpmuxActions?.[method];
  if (direct) return direct(params) as Promise<T>;
  return postNative<T>(method, params);
}

/// Hands the tail to the host for the next tab, bounded in records and bytes. Never awaited: an
/// open must not wait on it, and a host that refuses it only means the next tab opens cold.
function writeHostTail(sessionId: string, tail: KeptTail): void {
  const events = newestWithin(tail.events, HOST_TAIL_BYTES);
  if (events.length === 0) return;
  void callHost("chat.tail", {
    sessionId,
    tail: {
      ...tail,
      events,
      // Only a whole transcript is exhausted: a tail the byte bound cut has older events to read,
      // and a tail that claimed otherwise would hide them (test/reopened-chat-history.test.ts).
      historyExhausted: tail.historyExhausted && events.length === tail.events.length,
    },
  }).catch(() => undefined);
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

/// The host's answer as a tail, or undefined when it holds none or answers something else. Only
/// the shape the page wrote is read back; anything missing leaves the chat to open cold.
function tailFromHost(value: unknown): KeptTail | undefined {
  const tail = (value ?? undefined) as Partial<KeptTail> | undefined;
  if (!tail || typeof tail !== "object") return undefined;
  const events = Array.isArray(tail.events) ? tail.events.filter(isEventRecord) : [];
  if (events.length === 0) return undefined;
  return {
    events: events.slice(-KEPT_EVENTS),
    summary: typeof tail.summary === "object" && tail.summary !== null ? tail.summary : undefined,
    turnOpener: isEventRecord(tail.turnOpener) ? tail.turnOpener : undefined,
    historyExhausted: tail.historyExhausted === true && events.length <= KEPT_EVENTS,
    queue: Array.isArray(tail.queue) ? (tail.queue as QueuedPrompt[]) : [],
    configSeq: typeof tail.configSeq === "number" ? tail.configSeq : 0,
    usageFromSeq: typeof tail.usageFromSeq === "number" ? tail.usageFromSeq : 0,
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
  reading.clear();
}
