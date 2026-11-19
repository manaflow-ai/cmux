// The emoji table's search text is folded while the page is idle (emojiShortcodes.ts warmIdle), right
// after the person's first key in a composer. An idle period can be 50 ms long, and the fold used to
// fill it: one ~40 ms task the second key waited behind. Each slice now stops after WARM_SLICE_MS.
import { describe, expect, test } from "bun:test";
import { decodeEmojiTable, type RawEmojiTable } from "../src/icon-picker/emojiData";
import raw from "../src/icon-picker/generated/emoji-data.json";
import * as shortcodes from "../src/agent-session/acpmux/emojiShortcodes";

describe("emoji search-text warm-up", () => {
  test("folds every record in short slices, never one long idle task", async () => {
    const records = decodeEmojiTable(raw as unknown as RawEmojiTable).records;
    // A clock that moves 1 ms per record folded: the full table is ~1,900 ms of "work", so a slice
    // bounded only by the idle deadline would fold ~48 records, and one bounded by WARM_SLICE_MS 4.
    let clock = 0;
    const timed = records.map((record) => ({
      get searchText() {
        clock += 1;
        return record.searchText;
      },
    })) as unknown as typeof records;
    const queue: Array<(deadline?: IdleDeadline) => void> = [];
    const slices: number[] = [];
    const idle = (run: (deadline?: IdleDeadline) => void) => queue.push(run);
    const warm = (shortcodes as { warmIdle?: typeof shortcodes.warmIdle }).warmIdle;
    expect(typeof warm).toBe("function");
    warm!(timed, 0, () => clock, idle);
    while (queue.length) {
      const start = clock;
      // An idle period of the full 50 ms.
      queue.shift()!({ didTimeout: false, timeRemaining: () => Math.max(0, 50 - (clock - start)) });
      slices.push(clock - start);
    }
    expect(slices.reduce((sum, n) => sum + n, 0)).toBe(records.length);
    expect(Math.max(...slices)).toBeLessThanOrEqual(shortcodes.WARM_SLICE_MS + 1);
  });

  test("a deadline shorter than the slice budget ends the slice sooner", () => {
    const queue: Array<(deadline?: IdleDeadline) => void> = [];
    let clock = 0;
    const timed = Array.from({ length: 10 }, () => ({
      get searchText() {
        clock += 1;
        return "";
      },
    })) as unknown as Parameters<typeof shortcodes.warmIdle>[0];
    shortcodes.warmIdle(
      timed,
      0,
      () => clock,
      (run) => queue.push(run),
    );
    const start = clock;
    queue.shift()!({ didTimeout: false, timeRemaining: () => 2 });
    // One record at least, then the deadline (2 ms less the 1 ms margin) stops it.
    expect(clock - start).toBe(1);
  });
});
