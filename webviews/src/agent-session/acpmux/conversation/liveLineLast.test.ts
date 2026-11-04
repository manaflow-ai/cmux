// The running turn's live line stays the transcript's last row: rows the page appends after the
// turn (the waiting messages' group, a guest's prompt, an aside) draw above it (liveLineLast.ts).
import { describe, expect, test } from "bun:test";
import type { AcpmuxRow } from "../model";
import { liveLineLast } from "./liveLineLast";
import { PENDING_MESSAGES_ROW_ID } from "./pendingMessages";
import { ACTIVITY_LINE, THINKING, WORKING } from "./turns";

const row = (id: string, kind: string, extra: Partial<AcpmuxRow> = {}): AcpmuxRow =>
  ({ id, kind, at: 0, version: 1, ...extra }) as AcpmuxRow;
const live = row("thinking-live", THINKING, { below: true });
const ids = (rows: readonly AcpmuxRow[]) => rows.map((r) => r.id);

describe("liveLineLast", () => {
  test("another session's waiting message that arrived mid-turn draws above the live line", () => {
    const rows = [row("p", "user"), row("work", "activity"), live, row(PENDING_MESSAGES_ROW_ID, "pendingMessages")];
    expect(ids(liveLineLast(rows))).toEqual(["p", "work", PENDING_MESSAGES_ROW_ID, "thinking-live"]);
  });

  test("a guest's prompt and an aside after the line go above it too, in their order", () => {
    const rows = [row("p", "user"), live, row("guest", "queuedMessage"), row("btw-1", "btw")];
    expect(ids(liveLineLast(rows))).toEqual(["p", "guest", "btw-1", "thinking-live"]);
  });

  test("every live line kind moves: working and a plan's activity line", () => {
    for (const kind of [WORKING, ACTIVITY_LINE]) {
      const line = row("line", kind, { below: true });
      expect(ids(liveLineLast([row("p", "user"), line, row("g", "pendingMessages")]))).toEqual(["p", "g", "line"]);
    }
  });

  test("the same array when the line is already last, or there is none", () => {
    const last = [row("p", "user"), live];
    expect(liveLineLast(last)).toBe(last);
    const ended = [row("p", "user"), row("s", "turnSummary"), row(PENDING_MESSAGES_ROW_ID, "pendingMessages")];
    expect(liveLineLast(ended)).toBe(ended);
    // A prompt still waiting for its agent draws a Thinking line that is not the turn's bottom line.
    const waiting = [row("p", "user"), row("thinking-live", THINKING), row("g", "pendingMessages")];
    expect(liveLineLast(waiting)).toBe(waiting);
  });
});
