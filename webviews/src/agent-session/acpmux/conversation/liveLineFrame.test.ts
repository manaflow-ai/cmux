// Leo, 2026-11-25: "when you press enter, the stuff should just start playing. we dont need to
// wait/get blocked by anything on rendering". A prompt queued while a /compact ran: when the queue
// card left, the /compact's live line went on as the prompt's "Thinking" line and the room the card
// left under it was held, so the reply's first row pushed that line down (snappy-bench
// mid_compaction: a layout shift of a row on screen each time).
import { expect, test } from "bun:test";
import type { AcpmuxRow } from "../model";
import { rowFrameKey } from "../model";
import { promptLanded } from "../transcript/arrivals";
import { LIVE_THINKING, THINKING, liveLineFrame, turnView } from "./turns";

const prompt = (id: string, at: number, text: string, extra: Partial<AcpmuxRow> = {}): AcpmuxRow => ({
  id,
  version: 1,
  at,
  kind: "user",
  text,
  ...extra,
});
const line = (rows: AcpmuxRow[]) =>
  turnView(rows, new Set(), { now: 10_000, working: true }).find((row) => row.id === LIVE_THINKING);

test("each prompt's turn draws its live line in a frame of its own", () => {
  const compact = prompt("local-compact", 1_000, "/compact");
  const queued = prompt("local-next", 5_000, "next");
  const first = line([compact]);
  const second = line([
    compact,
    { id: "compaction", version: 1, at: 4_000, kind: "assistant", text: "Conversation compacted" },
    queued,
  ]);
  expect(first?.kind).toBe(THINKING);
  expect(second?.kind).toBe(THINKING);
  // One id for every running turn's line (turnEndFold.ts reads it), but a frame each.
  expect(first!.id).toBe(second!.id);
  expect(rowFrameKey(first!)).not.toBe(rowFrameKey(second!));
});

test("the line keeps its frame when acpmux's echo renames the sent prompt's row", () => {
  const sent = prompt("local-p1", 1_000, "hello", { pending: true });
  const echoed = prompt("user-7", 1_000, "hello", { promptId: "p1" });
  expect(liveLineFrame(sent)).toBe(liveLineFrame(echoed));
  expect(rowFrameKey(line([sent])!)).toBe(rowFrameKey(line([echoed])!));
});

test("a queued prompt whose row already landed is no prompt still coming", () => {
  const rows: AcpmuxRow[] = [
    prompt("local-compact", 1_000, "/compact"),
    prompt("local-p2", 5_000, "next"),
    { id: LIVE_THINKING, version: 1, at: 5_000, kind: THINKING, below: true },
  ];
  expect(promptLanded(rows, "p2")).toBe(true);
  // Not landed yet (the card leaves first), withdrawn, or no id: room is still held for it.
  expect(promptLanded(rows, "p3")).toBe(false);
  expect(promptLanded(rows, "")).toBe(false);
  // Only a prompt's own row counts, not another row that shares the id.
  expect(promptLanded([{ id: "local-p4", version: 1, at: 1, kind: "assistant", text: "x" }], "p4")).toBe(false);
});
