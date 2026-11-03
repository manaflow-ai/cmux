// A view that reads the pane's rows (Find, an open artifact) opening while a streamed chunk is held
// in the streaming row's store (streamingRow.ts) gets the newest rows at once: the pane draws its
// latest snapshot when the block turns on (review of #34004, hpa-stream-reviewer-3: Find opened in a
// pause of a reply searched the older rows until the next event). HOT PATH AUDIT area F, row W1.
import { afterEach, expect, test } from "bun:test";
import type { AcpmuxRow } from "../src/agent-session/acpmux/model";
import { onStreamingRowBlocked, setStreamingRowBlocked, streamingRow } from "../src/agent-session/acpmux/streamingRow";

const row = (version: number, text: string): AcpmuxRow =>
  ({ id: "reply", version, at: 1, kind: "assistant", text, streaming: true }) as AcpmuxRow;

afterEach(() => {
  setStreamingRowBlocked(false, "find");
  setStreamingRowBlocked(false, "artifact");
  streamingRow.clear();
});

test("a block that turns on while a chunk is held asks the pane to draw once", () => {
  let draws = 0;
  const stop = onStreamingRowBlocked(() => {
    draws += 1;
    streamingRow.clear();
  });
  try {
    streamingRow.set(row(3, "one two three"), row(1, "one"));
    setStreamingRowBlocked(true, "find");
    expect(draws).toBe(1);
    expect(streamingRow.get()).toBeUndefined();
    // Already blocked, or a second blocker: nothing held, nothing to draw.
    setStreamingRowBlocked(true, "artifact");
    expect(draws).toBe(1);
  } finally {
    stop();
  }
});

test("a block with nothing held draws nothing", () => {
  let draws = 0;
  const stop = onStreamingRowBlocked(() => void (draws += 1));
  try {
    setStreamingRowBlocked(true, "find");
    expect(draws).toBe(0);
  } finally {
    stop();
  }
});
