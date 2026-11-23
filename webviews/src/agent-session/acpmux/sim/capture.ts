// Turning a reported breakage into a chat-sim fixture (sim/README.md "Capture a reported breakage").
//
// Leo, 2026-11-22: "you guys need to be able to rapidly pull up and develop against these scenarios,
// just like the offline simulator."
//
// He reports a breakage as a time window on his clock ("2:05PM NOV 22 TO 2:11PM"), or by writing about
// it in the chat it happened in. This file finds the records of that window in a session's log: the
// window's clock times read in his zone, or the minutes before the prompt he reported it in, widened back
// to the start of the turn that was running when the window opened, so the reducer folds the window
// with the state it had live.
import { intl } from "../../../ui/intl";
import type { EventRecord } from "../direct";

/** Leo's clock (his "2:05PM NOV 22" is 22:05Z). */
export const DEFAULT_ZONE = "America/Los_Angeles";

const MONTHS = ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"];

/** The zone's offset from UTC at `utcMs`, in ms (positive east of UTC). */
function zoneOffsetMs(zone: string, utcMs: number): number {
  const parts = Object.fromEntries(
    intl
      .DateTimeFormat("en-US", {
        timeZone: zone,
        hourCycle: "h23",
        year: "numeric",
        month: "2-digit",
        day: "2-digit",
        hour: "2-digit",
        minute: "2-digit",
        second: "2-digit",
      })
      .formatToParts(new Date(utcMs))
      .map((part) => [part.type, part.value]),
  );
  const asUtc = Date.UTC(
    Number(parts.year),
    Number(parts.month) - 1,
    Number(parts.day),
    Number(parts.hour),
    Number(parts.minute),
    Number(parts.second),
  );
  return asUtc - Math.floor(utcMs / 1000) * 1000;
}

/** A wall-clock time in `zone` as UTC ms. */
function zonedToUtc(zone: string, y: number, mo: number, d: number, h: number, mi: number, s: number): number {
  const guess = Date.UTC(y, mo, d, h, mi, s);
  const first = guess - zoneOffsetMs(zone, guess);
  return guess - zoneOffsetMs(zone, first);
}

export type ClockContext = {
  /** The zone a time with no `Z` or offset is read in. */
  zone?: string;
  /** A time with no date takes this one's date (in the zone): the session's last record, or the window's start. */
  near: number;
};

/// One time as Leo or an agent writes it, as UTC ms: an ISO time (`2026-11-22T22:05:00Z`), a UTC clock time
/// (`22:05Z`), or a clock time on his clock (`2:05PM`, `2:05 pm nov 22`, `14:05`, `nov 22 2:05pm`).
/// Undefined when it reads as none of these.
export function parseClock(text: string, context: ClockContext): number | undefined {
  const raw = text.trim();
  if (/^\d{4}-\d\d-\d\dT/.test(raw)) {
    const ms = Date.parse(raw);
    return Number.isNaN(ms) ? undefined : ms;
  }
  const lower = raw.toLowerCase().replace(/,/g, " ");
  const time = lower.match(/\b(\d{1,2})(?::(\d\d))?(?::(\d\d))?\s*(am|pm)?\s*(z|utc)?\b/);
  if (!time || (time[2] === undefined && time[4] === undefined)) return undefined;
  let hour = Number(time[1]);
  const minute = Number(time[2] ?? 0);
  const second = Number(time[3] ?? 0);
  if (time[4] === "pm" && hour < 12) hour += 12;
  if (time[4] === "am" && hour === 12) hour = 0;
  if (hour > 23 || minute > 59 || second > 59) return undefined;
  const utc = time[5] !== undefined;
  const zone = utc ? "UTC" : (context.zone ?? DEFAULT_ZONE);
  const nearLocal = new Date(context.near + zoneOffsetMs(zone, context.near));
  let year = nearLocal.getUTCFullYear();
  let month = nearLocal.getUTCMonth();
  let day = nearLocal.getUTCDate();
  const named = lower.match(new RegExp(`\\b(${MONTHS.join("|")})[a-z]*\\.?\\s*(\\d{1,2})\\b`));
  if (named) {
    month = MONTHS.indexOf(named[1]!);
    day = Number(named[2]);
    const year4 = lower.match(/\b(20\d\d)\b/);
    if (year4) year = Number(year4[1]);
  }
  return zonedToUtc(zone, year, month, day, hour, minute, second);
}

/// A window as he writes it: `2:05PM NOV 22 TO 2:11PM`, `22:05Z-22:11Z`, `2:05pm..2:11pm`, or one time
/// (the window is then `minutes` long, ending there). The end takes the start's date when it names none,
/// and a day later when it would fall before the start.
export function parseWindow(text: string, context: ClockContext & { minutes?: number }): [number, number] | undefined {
  const sides = text.split(/\s+(?:to|until|till|through)\s+|\s*(?:\.\.|–|—)\s*|(?<=\d:\d\d|[ap]m|z)\s*-\s*(?=\d)/i);
  const start = parseClock(sides[0] ?? "", context);
  if (start === undefined) return undefined;
  if (sides.length < 2) return [start - (context.minutes ?? 6) * 60_000, start];
  let end = parseClock(sides[1]!, { ...context, near: start });
  if (end === undefined) return undefined;
  if (end < start) end += 86_400_000;
  return [start, end];
}

/** The prompt text of a record the person sent (a `user_message` or `turn_started` with their text). */
function personPrompt(record: EventRecord): string | undefined {
  if (record.kind !== "user_message") return undefined;
  const msg = record.msg as { text?: unknown; _meta?: { origin?: { actor?: unknown } } };
  if (msg?._meta?.origin?.actor !== "person" || typeof msg.text !== "string") return undefined;
  return msg.text;
}

/// The person's prompt that reported the breakage: the last one whose text holds `text` (case and spacing
/// ignored), or the last of theirs at all when `text` is empty.
export function findReport(records: readonly EventRecord[], text: string): EventRecord | undefined {
  const want = text.toLowerCase().replace(/\s+/g, " ").trim();
  for (let index = records.length - 1; index >= 0; index -= 1) {
    const prompt = personPrompt(records[index]!);
    if (prompt === undefined) continue;
    if (!want || prompt.toLowerCase().replace(/\s+/g, " ").includes(want)) return records[index];
  }
  return undefined;
}

export type CaptureRange = {
  /** The window, UTC ms. */
  start: number;
  end: number;
  /** The seqs kept: from the lead-in's first record to the window's last. */
  fromSeq: number;
  toSeq: number;
  /** Records kept before the window opened (the running turn's lead-in). */
  leadIn: number;
  /** Records inside the window. */
  inWindow: number;
};

/// The records a window needs: those at or after `start` and at or before `end`, widened back to the
/// `turn_started` of the turn running at `start` (when `lead` is "turn", the default), so the reducer
/// has the turn's rows before the window's first record lands.
export function pickRange(
  records: readonly EventRecord[],
  start: number,
  end: number,
  lead: "turn" | "none" = "turn",
): CaptureRange | undefined {
  const sorted = [...records].sort((a, b) => a.seq - b.seq);
  const inside = sorted.filter((record) => record.at >= start && record.at <= end);
  if (inside.length === 0) return undefined;
  let from = inside[0]!.seq;
  if (lead === "turn") {
    let ended = false;
    for (let index = sorted.findIndex((record) => record.seq === from) - 1; index >= 0; index -= 1) {
      const kind = sorted[index]!.kind;
      if (kind === "turn_result" || kind === "turn_end") ended = true;
      if (kind === "turn_started") {
        if (!ended) from = sorted[index]!.seq;
        break;
      }
    }
  }
  const to = inside.at(-1)!.seq;
  return {
    start,
    end,
    fromSeq: from,
    toSeq: to,
    leadIn: sorted.filter((record) => record.seq >= from && record.at < start).length,
    inWindow: inside.length,
  };
}

/** The records the pane reads first when it opens a chat: its last page (#51238: the daemon's settled view, 400). */
export const FIRST_PAGE = 400;

/// Where to start reading the fixture to model what the live pane read: the whole window, and the pane
/// opened (or reconnected) partway, reading only its last page of records, and half of it.
export function readOffsets(count: number): { name: string; from: number }[] {
  const out = [{ name: "whole", from: 0 }];
  if (count > FIRST_PAGE * 2) out.push({ name: `last ${FIRST_PAGE} (a page read)`, from: count - FIRST_PAGE });
  if (count > FIRST_PAGE * 4) out.push({ name: "second half (a reconnect)", from: Math.floor(count / 2) });
  return out;
}

/// A time as Leo reads it: his clock, with the UTC time beside it.
export function clockLabel(utcMs: number, zone = DEFAULT_ZONE): string {
  const local = intl
    .DateTimeFormat("en-US", {
      timeZone: zone,
      hour: "numeric",
      minute: "2-digit",
      second: "2-digit",
    })
    .format(new Date(utcMs));
  return `${local} (${new Date(utcMs).toISOString().slice(11, 19)}Z)`;
}
