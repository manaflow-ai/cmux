import { describe, expect, test } from "bun:test";
import type { AcpmuxRow } from "../model";
import {
  currentTurn,
  minimapTurns,
  popoverOffset,
  replyPreview,
  tickLayout,
  tickWidth,
  turnScrollTop,
  visibleTurns,
} from "./model";
import { createBookmarkStore } from "./bookmarks";

const row = (id: string, kind: string, text: string, at = 1): AcpmuxRow => ({ id, version: 1, at, kind, text });

describe("thread minimap turns", () => {
  test("one turn per user message, with the first reply after it", () => {
    const rows = [
      row("user-1", "user", "  first\n prompt "),
      row("a-1", "assistant", "Yes. **bold** reply"),
      row("a-2", "assistant", "second reply is ignored"),
      row("user-2", "user", "second"),
      row("tool-1", "activity", "tool"),
    ];
    const turns = minimapTurns(rows);
    expect(turns.map((turn) => [turn.index, turn.prompt])).toEqual([
      [0, "first prompt"],
      [3, "second"],
    ]);
    expect(turns[0].reply[0].spans).toEqual([
      { text: "Yes. ", bold: false },
      { text: "bold", bold: true },
      { text: " reply", bold: false },
    ]);
    expect(turns[1].reply).toEqual([]);
    // Another session's `user-1` is another turn; a later snapshot of this one is the same turn.
    expect(turns[0].key).not.toBe(minimapTurns([row("user-1", "user", "x")])[0].key);
    expect(turns[0].key).toBe(minimapTurns([row("user-1", "user", "  first\n prompt ", 9)])[0].key);
    expect(minimapTurns([row("user-1", "user", "same")], "session-a")[0].key).not.toBe(
      minimapTurns([row("user-1", "user", "same")], "session-b")[0].key,
    );
  });

  test("reply preview keeps bold, drops code and link targets, marks list items", () => {
    const blocks = replyPreview(
      "# Title\n\nSee [the docs](https://x) and `code`.\n\n```ts\nhidden\n```\n\n- one\n- __two__",
    );
    expect(blocks.map((block) => block.kind)).toEqual(["paragraph", "paragraph", "item", "item"]);
    expect(blocks[1].spans.map((span) => span.text).join("")).toBe("See the docs and code.");
    expect(blocks[3].spans).toEqual([{ text: "two", bold: true }]);
  });
});

describe("thread minimap geometry", () => {
  test("fisheye widths by distance from the hovered tick (measured: 26 20 14 10 6)", () => {
    expect([0, 1, 2, 3, 4, 9].map((d) => tickWidth(d))).toEqual([26, 20, 14, 10, 6, 6]);
    expect(tickWidth(undefined)).toBe(6);
  });

  test("ticks are centered in the viewport at a 10 px pitch, tighter when they do not fit", () => {
    expect(tickLayout(9, 400)).toEqual({ first: 160, pitch: 10 });
    const many = tickLayout(200, 400);
    expect(many.pitch).toBeLessThan(10);
    expect(many.first + many.pitch * 199).toBeLessThanOrEqual(400);
  });

  test("current turn reads layout tops, no DOM", () => {
    const tops = new Float64Array([0, 100, 400, 500, 900]);
    const turns = minimapTurns([
      row("user-1", "user", "a"),
      row("a", "assistant", ""),
      row("user-2", "user", "b"),
      row("b", "assistant", ""),
      row("user-3", "user", "c"),
    ]);
    expect(currentTurn(turns, tops, 0, 300)).toBe(0);
    expect(currentTurn(turns, tops, 350, 300)).toBe(1);
    expect(currentTurn(turns, tops, 850, 300)).toBe(2);
    expect(turnScrollTop(turns[1], tops)).toBe(400);
  });

  test("every turn in the viewport is lit (long-chat reference: a run of 2 to 7 ticks)", () => {
    const tops = new Float64Array([0, 100, 400, 500, 900]);
    const turns = minimapTurns([
      row("user-1", "user", "a"),
      row("a", "assistant", ""),
      row("user-2", "user", "b"),
      row("b", "assistant", ""),
      row("user-3", "user", "c"),
    ]);
    expect(visibleTurns(turns, tops, 1000, 0, 300)).toEqual({ first: 0, last: 0 });
    expect(visibleTurns(turns, tops, 1000, 350, 300)).toEqual({ first: 0, last: 1 });
    expect(visibleTurns(turns, tops, 1000, 450, 500)).toEqual({ first: 1, last: 2 });
  });

  test("popover centers on the tick and stays inside the viewport", () => {
    expect(popoverOffset(200, 104, 600)).toBe(148);
    expect(popoverOffset(10, 104, 600)).toBe(8);
    expect(popoverOffset(590, 104, 600)).toBe(488);
  });
});

describe("thread minimap bookmarks", () => {
  test("toggle, notify and persist", () => {
    const saved = new Map<string, string>();
    const storage = {
      getItem: (k: string) => saved.get(k) ?? null,
      setItem: (k: string, v: string) => void saved.set(k, v),
    };
    const store = createBookmarkStore(storage);
    let calls = 0;
    store.subscribe(() => (calls += 1));
    store.toggle("user-1#a");
    expect(store.has("user-1#a")).toBe(true);
    expect(calls).toBe(1);
    // A new snapshot per toggle, so memoized renders see the change.
    const first = store.snapshot();
    store.toggle("user-2#b");
    expect(store.snapshot()).not.toBe(first);
    store.toggle("user-2#b");
    expect(createBookmarkStore(storage).has("user-1#a")).toBe(true);
    store.toggle("user-1#a");
    expect(store.has("user-1#a")).toBe(false);
  });
});
