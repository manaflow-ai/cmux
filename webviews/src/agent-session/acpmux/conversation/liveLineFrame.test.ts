// l10n-allow-file: test fixture prompts and replies, not shipped UI.
// The live line draws in one element per turn (turns.ts `liveLineFrame`): the same element from the
// send to the turn's end, steers included, and an element of its own for the next turn. With one
// element for every turn, a turn that ended and the next that began in one update (a catch-up, a fast
// agent) moved the last turn's line down to the new bottom and faded it in again there: a layout
// shift of most of the view each turn (transcript-replay.bench.ts `transcript_replay.live.cls`, 0.38
// on the long log and 6.17 on the god session, all of it the live line). The tail glide
// (tailGlide.ts) plays no move for an element that took another's id: it was never drawn elsewhere.
import { afterEach, expect, test } from "bun:test";
import type { AcpmuxRow } from "../model";
import { rowFrameKey } from "../model";
import { foldMotion } from "./fold";
import { createTailGlide } from "./tailGlide";
import { LIVE_THINKING, THINKING, liveLineFrame, turnView } from "./turns";

const START = Date.UTC(2026, 10, 10, 1, 0, 0);
const row = (id: string, kind: string, second: number, extra: Partial<AcpmuxRow> = {}): AcpmuxRow => ({
  id,
  kind,
  version: 1,
  at: START + second * 1000,
  ...extra,
});
const view = (rows: AcpmuxRow[], working: boolean) =>
  turnView(rows, new Set(), { working, agentFamily: "claude", now: START + 900_000 });
const liveFrame = (rows: AcpmuxRow[], working: boolean) => {
  const last = view(rows, working).at(-1);
  expect({ kind: last?.kind, id: last?.id }).toEqual({ kind: THINKING, id: LIVE_THINKING });
  return rowFrameKey(last!);
};

const ended = [
  row("u-0", "user", 0, { text: "Deploy main" }),
  row("a-0", "assistant", 10, { text: "Deployed." }),
  row("s-0", "turnSummary", 11, { status: "completed", durationMs: 11_000, toolCount: 0 }),
];
const sent = row("u-1", "user", 60, { text: "Now the docs", pending: true });
const opened = { ...sent, pending: undefined, version: 2 };
const steer = row("u-2", "user", 70, { text: "and the changelog", pending: true });
const steerRead = { ...steer, pending: undefined, steer: "landed" as const, version: 3 };

test("one turn's live line keeps one frame from the send to its reply, through a steer", () => {
  const frames = new Set([
    liveFrame([...ended, sent], false),
    liveFrame([...ended, sent], true),
    liveFrame([...ended, opened], true),
    liveFrame([...ended, opened, steer], true),
    liveFrame([...ended, opened, steerRead], true),
    liveFrame([...ended, opened, steerRead, row("a-1", "assistant", 80, { text: "Updating the docs" })], true),
  ]);
  expect([...frames]).toEqual([liveLineFrame("u-1")]);
});

test("the next turn's live line is an element of its own, never the last turn's moved", () => {
  const first = liveFrame([...ended, opened], true);
  // The turn ended and the next began in one update, as a catch-up delivers them.
  const next = [
    ...ended,
    opened,
    row("a-1", "assistant", 80, { text: "Docs updated." }),
    row("s-1", "turnSummary", 81, { status: "completed", durationMs: 21_000, toolCount: 0 }),
    row("u-3", "user", 90, { text: "Ship it" }),
  ];
  const second = liveFrame(next, true);
  expect(second).not.toBe(first);
  expect(second).toBe(liveLineFrame("u-3"));
});

// A stand-in thread: each row's layout top (offsetTop) as the tail glide reads it.
type FakeRow = { dataset: { rowId: string }; offsetTop: number; animated: number; querySelector(): null; animate(): Animation };
const fakeRow = (id: string, top: number): FakeRow => {
  const row: FakeRow = {
    dataset: { rowId: id },
    offsetTop: top,
    animated: 0,
    querySelector: () => null,
    animate: () => {
      row.animated += 1;
      return { addEventListener() {}, cancel() {}, pause() {}, play() {}, playState: "running" } as unknown as Animation;
    },
  };
  return row;
};
const fakeThread = (rows: FakeRow[]) =>
  ({
    querySelectorAll: () => rows,
    closest: () => null,
    animate: () => undefined,
    ownerDocument: { defaultView: { getComputedStyle: () => ({ getPropertyValue: () => "" }) } },
  }) as unknown as HTMLElement;

const realDuration = foldMotion.duration;
const realReduced = foldMotion.reducedMotion;
afterEach(() => {
  foldMotion.duration = realDuration;
  foldMotion.reducedMotion = realReduced;
});

test("the tail glide plays no move for an element that took another element's id", () => {
  foldMotion.duration = () => 180;
  foldMotion.reducedMotion = () => false;
  const glide = createTailGlide();
  const anchor = fakeRow("a-0", 0);
  const oldLine = fakeRow(LIVE_THINKING, 100);
  glide.place(fakeThread([anchor, oldLine]), true, "a-0");
  // The same element moved under a row that came: it glides to its place.
  oldLine.offsetTop = 160;
  glide.place(fakeThread([anchor, oldLine]), true, "a-0");
  expect(oldLine.animated).toBe(1);
  // The next turn's line, a new element under the same id, far below: it draws where it came.
  const newLine = fakeRow(LIVE_THINKING, 900);
  glide.place(fakeThread([anchor, newLine]), true, "a-0");
  expect(newLine.animated).toBe(0);
});
