import { describe, expect, test } from "bun:test";
import { indexedPromptPlaceholders } from "../src/agent-session/acpmux/direct";
import type { AcpmuxRow } from "../src/agent-session/acpmux/model";
import { minimapTurns } from "../src/agent-session/acpmux/threadMinimap/model";

const prompt = (seq: number): AcpmuxRow => ({
  id: `user-${seq}`,
  version: 1,
  at: seq,
  seq,
  kind: "user",
  text: `Prompt ${seq}`,
});

describe("indexed rail target windows", () => {
  test("fills a sparse target page without moving its indexed prompt slots", () => {
    const indexed = Array.from({ length: 100 }, (_, index) => prompt(index + 1));
    const held = new Set([1, 100]);
    const placeholders = indexedPromptPlaceholders(indexed, held, 1, 100);
    expect(placeholders.map((row) => row.seq)).toEqual(Array.from({ length: 98 }, (_, index) => index + 2));

    const rows = [indexed[0]!, ...placeholders, indexed.at(-1)!];
    const turns = minimapTurns(rows, "indexed-rail");
    expect(turns.turns).toHaveLength(100);
    expect(turns.turns.map((turn) => turn.id)).toEqual(indexed.map((row) => row.id));
  });
});
