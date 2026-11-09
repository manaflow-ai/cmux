import { describe, expect, test } from "bun:test";

import type { AcpmuxRow } from "../model";
import { revealedSaid, saidRows } from "./saidReveal";

const row = (id: string, kind: string, text: string): AcpmuxRow => ({ id, version: 1, at: 0, kind, text });

describe("said reveal (the chats page opens a chat at the message it found)", () => {
  test("reads the role and the query's words, and nothing else", () => {
    expect(revealedSaid("said:answer:Cache  KEY cache")).toEqual({ answer: true, words: ["cache", "key"] });
    expect(revealedSaid("said:prompt:deploy")).toEqual({ answer: false, words: ["deploy"] });
    expect(revealedSaid("said:other:deploy")).toBeUndefined();
    expect(revealedSaid("said:answer:  ")).toBeUndefined();
    expect(revealedSaid("message:abc")).toBeUndefined();
  });

  test("the newest row of that kind holding every word, in any case", () => {
    const rows = [
      row("1", "user", "why does the cache key change"),
      row("2", "assistant", "The Cache key changes on every build."),
      row("3", "tool", "cache key"),
      row("4", "assistant", "Fixed: the key is stable, the CACHE stays."),
      row("5", "assistant", "only the cache"),
    ];
    expect(saidRows(rows, { answer: true, words: ["cache", "key"] })).toEqual(["4"]);
    expect(saidRows(rows, { answer: false, words: ["key", "cache"] })).toEqual(["1"]);
    expect(saidRows(rows, { answer: true, words: ["zephyrine"] })).toEqual([]);
    // A final sigma is folded as acpmux folds it.
    expect(
      saidRows([row("g", "user", "ΚΟΣΜΟΣ")], { answer: false, words: revealedSaid("said:prompt:κοσμος")!.words }),
    ).toEqual(["g"]);
    // A reply a tool call split: the newest row holding most of the words.
    expect(saidRows(rows, { answer: true, words: ["stable", "build"] })).toEqual(["4"]);
  });
});
