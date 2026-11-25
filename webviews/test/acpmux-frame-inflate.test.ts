// Compressed acpmux frames on a page's own network socket (frameInflate.ts; Leo, 2026-11-22: "get that gui agent
// chat sped up to be nearly as fast as the terminal coming back ... the agent gui needs that too"): who asks, what
// inflates, and that frames never reorder behind an inflate.
import { describe, expect, test } from "bun:test";
import zlib from "node:zlib";
import { initializeParams } from "../src/agent-session/acpmux/direct";
import { inflateFrame, offersFrameCompression, OrderedFrames } from "../src/agent-session/acpmux/frameInflate";

const big = JSON.stringify({
  jsonrpc: "2.0",
  id: 4,
  result: { events: Array.from({ length: 300 }, (_, i) => ({ seq: i, text: "an answer the chat drew" })) },
});
const zlibFrame = (text: string) => new Uint8Array(zlib.deflateSync(Buffer.from(text), { level: 1 })).buffer;

describe("who asks for compressed frames", () => {
  test("only a native WebSocket to another machine", () => {
    expect(offersFrameCompression("acpmux-websocket", "wss://machine.example:7777/")).toBe(true);
    expect(offersFrameCompression("acpmux-websocket", "ws://127.0.0.1:7777/")).toBe(false);
    expect(offersFrameCompression("acpmux-websocket", "ws://localhost:7777/")).toBe(false);
    expect(offersFrameCompression("acpmux-websocket", "ws://[::1]:7777/")).toBe(false);
    expect(offersFrameCompression("acpmux-bridge", "wss://machine.example/")).toBe(false);
    expect(offersFrameCompression("acpmux-websocket", undefined)).toBe(false);
  });

  test("initialize names zlib only when asked, beside what it always sends", () => {
    const always = { peerRowBatches: true, chunkDeltas: true, sessionChangedDelta: true };
    expect(initializeParams()._meta.acpmux).toEqual(always);
    expect(initializeParams(true)._meta.acpmux).toEqual({ ...always, compression: ["zlib"] });
  });
});

describe("inflating a frame", () => {
  test("a zlib frame inflates to its JSON text, from an ArrayBuffer or a Blob", async () => {
    expect(await inflateFrame(zlibFrame(big))).toBe(big);
    expect(await inflateFrame(new Blob([zlibFrame(big)]))).toBe(big);
  });

  test("a frame past the limit, or not zlib, is refused", async () => {
    await expect(inflateFrame(zlibFrame(big), 100)).rejects.toThrow(/inflates past 100 bytes/);
    await expect(inflateFrame(new Uint8Array([1, 2, 3, 4]).buffer)).rejects.toThrow();
  });
});

describe("frames in order", () => {
  test("text with nothing waiting goes at once; text after a binary frame waits for it", async () => {
    const got: string[] = [];
    const frames = new OrderedFrames(
      (text) => got.push(text),
      () => got.push("error"),
    );
    frames.push('{"id":1}');
    expect(got).toEqual(['{"id":1}']);
    frames.push(zlibFrame(big));
    frames.push('{"id":5}');
    expect(got).toEqual(['{"id":1}']);
    await frames.drained();
    expect(got).toEqual(['{"id":1}', big, '{"id":5}']);
    frames.push('{"id":6}');
    expect(got.at(-1)).toBe('{"id":6}');
  });

  test("a frame that does not inflate ends the stream once, and nothing after it is handed on", async () => {
    const got: string[] = [];
    let errors = 0;
    const frames = new OrderedFrames(
      (text) => got.push(text),
      () => (errors += 1),
    );
    frames.push(new Uint8Array([9, 9, 9]).buffer);
    frames.push('{"id":2}');
    frames.push(new Uint8Array([9, 9, 9]).buffer);
    await frames.drained();
    expect(errors).toBe(1);
    expect(got).toEqual([]);
  });
});
