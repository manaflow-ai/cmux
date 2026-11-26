// Leo, 2026-11-22: "just saw a composer flicker/re-render when for some reason there's also a ton of
// space at the bottom? idk if it was accounting maybe for tool calls in a long steered with attachment
// situation like... and then i scrolled up and then the composer flickered. weird state around here
// all-around. the whole situation needs to be audited and sniffed out"
//
// The room under the last row is held while the reader is scrolled up (VirtualTranscript `heldRoom`),
// and kept when they scroll back down so cutting it moves nothing they look at (Leo, 2026-11-20). A
// stack that was tall when they scrolled up (a steer's image previews and queued cards over the
// composer) left that whole height kept under the live line for the rest of the turn: every row the
// turn brought landed above it, so the band never closed. The kept room is space the rows fill.
import { expect, test } from "bun:test";
import { roomUnderRows } from "../src/agent-session/acpmux/conversation/roomUnder";

const STACK = 96; // the stack's room once the steer went: the composer card and the rest gap
const HELD = 380; // the room held while scrolled up: composer + two image previews + a queued steer card

type Held = Parameters<typeof roomUnderRows>[0];

function pass(held: Held, tail: number, following = true) {
  const out = roomUnderRows(held, {
    following,
    sessionSwitched: false,
    followedRoom: STACK,
    prompt: "prompt-1",
    tail: () => tail,
  });
  // What the placement pass stores for the next pass (VirtualTranscript: the layout effect and `heldRoom.room`).
  return {
    out,
    next: { room: out.room, reader: { followed: following, kept: out.kept } } satisfies Held,
  };
}

test("back at the latest row, the room held while scrolled up is kept: nothing the reader sees moves", () => {
  const { out } = pass({ room: HELD, reader: { followed: false, left: true } }, 1000);
  expect(out.room).toBe(HELD);
  // The rows' end with the room is where it was drawn.
  expect(1000 + out.room).toBe(1000 + HELD);
});

test("rows the turn brings fill the kept room, and its end stays where it was drawn", () => {
  let state = pass({ room: HELD, reader: { followed: false, left: true } }, 1000).next;
  const end = 1000 + HELD;
  // A notification row, a tool row and an agent message arrive under the live Thinking line.
  for (const tail of [1044, 1088, 1160]) {
    const { out, next } = pass(state, tail);
    expect(tail + out.room).toBe(end);
    state = next;
  }
  expect(state.room).toBe(end - 1160);
});

test("once the rows reach the stack's room, the gap under the last row is the rest gap again", () => {
  let state = pass({ room: HELD, reader: { followed: false, left: true } }, 1000).next;
  for (const tail of [1100, 1250, 1300, 1400]) state = pass(state, tail).next;
  expect(state.room).toBe(STACK);
  expect(state.reader.kept).toBeUndefined();
  // And it stays the stack's room as more rows come: no kept room comes back.
  expect(pass(state, 1500).out.room).toBe(STACK);
});

test("a row that leaves (Thinking giving way) keeps the end in place instead of pulling the rows down", () => {
  const state = pass({ room: HELD, reader: { followed: false, left: true } }, 1000).next;
  const { out } = pass(state, 970);
  expect(970 + out.room).toBe(1000 + HELD);
});

test("scrolled up, the room stays as held", () => {
  const { out } = pass({ room: HELD, reader: { followed: false, left: true } }, 1200, false);
  expect(out.room).toBe(HELD);
  expect(out.kept).toBeUndefined();
});
