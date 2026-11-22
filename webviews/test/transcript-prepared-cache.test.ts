import { expect, test } from "bun:test";
import type { PreparedText } from "@chenglou/pretext";
import { layoutConversation, PREPARED_CACHE_SPARE, type PreparedRow } from "../src/agent-session/acpmux/model";

class CountingPrepared extends Map<string, PreparedText | null> {
  misses = 0;

  override get(key: string): PreparedText | null | undefined {
    const value = super.get(key);
    if (value === undefined) this.misses += 1;
    return value;
  }
}

const reply = (text: string) => ({ id: "streaming", version: 1, at: 0, kind: "assistant", text });
const blocks = (count: number) =>
  Array.from({ length: count }, (_, index) => `Block ${index} ${"word ".repeat(8)}`).join("\n\n");
const list = (count: number) => Array.from({ length: count }, (_, index) => `- Item ${index}`).join("\n");

test("a streamed 200-block reply prepares only each new tail version", () => {
  const prepared = new CountingPrepared();
  const cache = new Map<string, PreparedRow>();
  cache.set("streaming", {
    text: "",
    blocks: [],
    closedBlocks: [],
    closedEnd: 0,
    lexedLength: 0,
    prepared,
  });

  let text = blocks(200);
  let previousMisses = 0;
  for (let delta = 0; delta < 5; delta += 1) {
    layoutConversation([reply(text)] as never, 720, cache);
    const remeasuredThisDelta = prepared.misses - previousMisses;
    expect(remeasuredThisDelta).toBe(delta === 0 ? 200 : 1);
    previousMisses = prepared.misses;
    text += `\n\nTail ${delta} ${"word ".repeat(8)}`;
  }
});

test("a streamed 500-item list keeps stable item preparations", () => {
  const prepared = new CountingPrepared();
  const cache = new Map<string, PreparedRow>();
  cache.set("streaming-list", {
    text: "",
    blocks: [],
    closedBlocks: [],
    closedEnd: 0,
    lexedLength: 0,
    prepared,
  });

  let text = list(500);
  let previousMisses = 0;
  for (let delta = 0; delta < 5; delta += 1) {
    layoutConversation([{ ...reply(text), id: "streaming-list" }] as never, 720, cache);
    const remeasuredThisDelta = prepared.misses - previousMisses;
    expect(remeasuredThisDelta).toBe(delta === 0 ? 500 : 1);
    previousMisses = prepared.misses;
    text += `\n- Tail ${delta}`;
  }
});

// cmux#45888: every streamed revision of a reply's tail block is a new key (font and text), and a
// tail never streams back to an earlier text, so a revision this measure did not use is dead. The
// per-row cache kept up to max(64, 4 x blocks) of them, each a whole prepared block, in every row
// of every chat the shared chat renderer holds: a session of streaming agents filled it until it hung.
test("a streamed reply keeps only the revisions its last measure used, plus a small spare", () => {
  const prepared = new Map<string, PreparedText | null>();
  const cache = new Map<string, PreparedRow>();
  cache.set("streaming", { text: "", blocks: [], closedBlocks: [], closedEnd: 0, lexedLength: 0, prepared });

  // One paragraph that grows chunk by chunk, as a streamed reply does.
  let text = "";
  for (let chunk = 0; chunk < 200; chunk += 1) {
    text += `Line ${chunk}: seq 1 400 printed four hundred numbers, then exited 0. `;
    layoutConversation([reply(text)] as never, 720, cache);
  }
  expect(prepared.size).toBeLessThanOrEqual(1 + PREPARED_CACHE_SPARE);

  // A long reply of 50 blocks with a streaming tail: its 50 closed blocks stay, the dead tails go.
  const many = new Map<string, PreparedText | null>();
  cache.set("streaming", { text: "", blocks: [], closedBlocks: [], closedEnd: 0, lexedLength: 0, prepared: many });
  let long = blocks(50);
  for (let chunk = 0; chunk < 200; chunk += 1) {
    long += ` word${chunk}`;
    layoutConversation([reply(long)] as never, 720, cache);
  }
  expect(many.size).toBeLessThanOrEqual(50 + PREPARED_CACHE_SPARE);
});
