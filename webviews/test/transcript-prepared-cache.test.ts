import { expect, test } from "bun:test";
import type { PreparedText } from "@chenglou/pretext";
import { layoutConversation, type PreparedRow } from "../src/agent-session/acpmux/model";

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
