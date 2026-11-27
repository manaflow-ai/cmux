// The restart-to-settled harness's pure parts (Leo, 2026-11-22: "you guys need to be able to simulate the
// update/restart and the connection speed and what is actually displayed"): the simulated link's schedule
// (bench/linkModel.ts) and the numbers read from a relaunch's painted frames (bench/restartSettled.ts).
import { describe, expect, test } from "bun:test";
import { LinkPipe, linkProfile, linkProfiles, schedule, ZLIB_MIN_BYTES, zlibWire } from "../bench/linkModel";
import { movedPx, restartSettled, goneRows } from "../bench/restartSettled";
import { classifyFrames, type FrameRecord } from "../src/agent-session/acpmux/firstLoadFrames";

describe("link model", () => {
  test("every profile the harness names exists, and local is free", () => {
    const profiles = linkProfiles();
    for (const name of ["local", "rtt50", "rtt200", "throttled"]) expect(profiles[name]).toBeDefined();
    expect(linkProfile("local")).toEqual({ rttMs: 0, bps: 0 });
    expect(() => linkProfile("dialup")).toThrow(/LINK must be one of/);
  });

  test("a message arrives half a round trip after it departs, and waits for the pipe", () => {
    const profile = { rttMs: 200, bps: 1_000_000 };
    // 12,500 bytes is 100 ms on the wire at 1 Mbit/s.
    const first = schedule(profile, 0, 0, 12_500);
    expect(first).toEqual({ departAt: 100, arriveAt: 200 });
    // Handed over at 10 ms, behind the first: it departs when the pipe is free plus its own 100 ms.
    const second = schedule(profile, 10, first.departAt, 12_500);
    expect(second).toEqual({ departAt: 200, arriveAt: 300 });
    // Unlimited bandwidth: latency only.
    expect(schedule({ rttMs: 50, bps: 0 }, 5, 0, 1_000_000)).toEqual({ departAt: 5, arriveAt: 30 });
  });

  test("a pipe delivers in order, and a closed one delivers nothing more", async () => {
    let now = 0;
    const pipe = new LinkPipe({ rttMs: 20, bps: 0 }, () => now);
    const got: string[] = [];
    pipe.send("a", (m) => got.push(m));
    pipe.send("b", (m) => got.push(m));
    // fixed-wait: the pipe's 10 ms one-way delay is what is under test; 40 ms is past both deliveries.
    await new Promise((resolve) => setTimeout(resolve, 40));
    expect(got).toEqual(["a", "b"]);
    now = 100;
    pipe.send("c", (m) => got.push(m));
    pipe.close();
    // fixed-wait: a closed pipe delivers nothing; the assertion is that no delivery comes in this window.
    await new Promise((resolve) => setTimeout(resolve, 40));
    expect(got).toEqual(["a", "b"]);
    expect(pipe.bytes).toBe(3);
  });

  test("with zlib, a large line crosses deflated and arrives whole; a small one crosses as text", () => {
    const row = JSON.stringify({ kind: "agent_message_chunk", text: "the chat's answer, repeated as chats repeat" });
    const large = Array.from({ length: 400 }, () => row).join(",");
    expect(large.length).toBeGreaterThanOrEqual(ZLIB_MIN_BYTES);
    expect(zlibWire(large).bytes).toBeLessThan(large.length / 4);
    expect(zlibWire("small")).toEqual({ bytes: 5, deflated: null });
    const pipe = new LinkPipe({ rttMs: 0, bps: 0 }, undefined, true);
    const got: string[] = [];
    pipe.send(large, (m) => got.push(m));
    pipe.send("small", (m) => got.push(m));
    expect(got).toEqual([large, "small"]);
    expect(pipe.bytes).toBe(zlibWire(large).bytes + 5);
  });

  test("a local pipe delivers at once", () => {
    const pipe = new LinkPipe({ rttMs: 0, bps: 0 });
    const got: string[] = [];
    pipe.send("now", (m) => got.push(m));
    expect(got).toEqual(["now"]);
  });
});

const COMPOSER = { top: 680, height: 96 };
const frame = (t: number, rows: { id: string; top: number; text?: string }[], composer = COMPOSER): FrameRecord => ({
  t,
  copyShown: false,
  rows,
  composer,
  scrollTop: 0,
});

describe("restart to settled", () => {
  test("a first frame that is the final one settles when the live chat shows", () => {
    const rows = [{ id: "a", top: 100 }];
    const frames = [frame(80, rows), frame(96, rows), frame(700, rows)];
    const got = restartSettled(frames, classifyFrames(frames), 650);
    expect(got).toEqual({
      firstContentMs: 80, // motion-allow: a frame time in the fixture, not a motion step
      settledMs: 650,
      shifts: 0,
      shiftPxMax: 0,
      shiftPxSum: 0,
      goneRows: 0,
      goneFrames: 0,
    });
  });

  test("a move after the live chat showed settles at the move, and counts how far it went", () => {
    const frames = [
      frame(80, [{ id: "a", top: 100 }]),
      frame(600, [{ id: "a", top: 100 }]),
      frame(720, [{ id: "a", top: 60 }]),
      frame(740, [{ id: "a", top: 60 }]),
    ];
    const got = restartSettled(frames, classifyFrames(frames), 600);
    expect(got.settledMs).toBe(720);
    expect(got.shifts).toBe(1);
    expect(got.shiftPxMax).toBe(40);
  });

  test("a chat that never went live has not settled", () => {
    const rows = [{ id: "a", top: 100 }];
    const frames = [frame(80, rows)];
    expect(restartSettled(frames, classifyFrames(frames), null).settledMs).toBeNull();
  });

  test("rows a reload drew and the settled chat folded away count once each, with the frames that showed them", () => {
    // Leo, 2026-11-22: "they get folded/hidden anyways: so its quite pointless ... to stream them in".
    const frames = [
      frame(80, [
        { id: "call-1", top: 100 },
        { id: "call-2", top: 140 },
      ]),
      frame(96, [
        { id: "call-1", top: 100 },
        { id: "call-2", top: 140 },
        { id: "reply", top: 180 },
      ]),
      frame(700, [
        { id: "worked", top: 100 },
        { id: "reply", top: 140 },
      ]),
    ];
    expect(goneRows(frames)).toEqual({ rows: 2, frames: 2 });
    expect(restartSettled(frames, classifyFrames(frames), 650)).toMatchObject({ goneRows: 2, goneFrames: 2 });
    expect(goneRows([frame(80, [{ id: "a", top: 100 }])])).toEqual({ rows: 0, frames: 0 });
    expect(goneRows([])).toEqual({ rows: 0, frames: 0 });
  });

  test("a row drawn under another id with the same words is the same row, not a gone one", () => {
    // The copy draws v1's row ids; the row store's page draws the same rows as `row-N`.
    const frames: FrameRecord[] = [
      frame(80, [{ id: "evt-9", top: 100, text: "Answer" }]),
      frame(700, [{ id: "row-9", top: 100, text: "Answer" }]),
    ];
    expect(goneRows(frames)).toEqual({ rows: 0, frames: 0 });
    frames.unshift(frame(60, [{ id: "evt-8", top: 60, text: "Ran 4 commands" }]));
    expect(goneRows(frames)).toEqual({ rows: 1, frames: 1 });
  });

  test("a composer that grew counts its growth; sub-pixel rounding counts nothing", () => {
    const rows = [{ id: "a", top: 100 }];
    expect(movedPx(frame(0, rows), frame(1, rows, { top: 660, height: 116 }))).toBe(20);
    expect(movedPx(frame(0, rows), frame(1, [{ id: "a", top: 100.5 }]))).toBe(0);
  });
});
