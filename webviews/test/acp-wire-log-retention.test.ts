// A long message the wire log cuts to MAX_PAYLOAD_CHARS keeps only the cut, not the whole message: a slice shares its
// source's buffer, so each kept cut of a 1 MB frame held the frame (src/agent-session/acpmux/wire.ts, `ownCopy`).
/// <reference types="bun" />
import { expect, test } from "bun:test";
import { heapStats } from "bun:jsc";
import { AcpWireLog, MAX_PAYLOAD_CHARS } from "../src/agent-session/acpmux/wire";

test("a cut message keeps its cut, not the whole frame", () => {
  const log = new AcpWireLog();
  const frames = 40;
  const size = 1 << 20;
  Bun.gc(true);
  const before = heapStats().heapSize;
  for (let index = 0; index < frames; index++) {
    // A flat frame of its own each time (a reply's text as the socket hands it over).
    const text = JSON.stringify({
      jsonrpc: "2.0",
      method: "_acpmux/event",
      params: { index, blob: `${index}`.padEnd(size, "z") },
    });
    log.received(text);
  }
  Bun.gc(true);
  const kept = heapStats().heapSize - before;
  const entries = log.entries();
  expect(entries).toHaveLength(frames);
  expect(entries.every((entry) => entry.truncated && entry.text?.length === MAX_PAYLOAD_CHARS)).toBe(true);
  // The cuts are 40 x 16 K characters (under 1.5 MB with the entries); the frames were 40 MB.
  expect(kept).toBeLessThan(8 * size);
});
