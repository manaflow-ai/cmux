import { expect, test } from "bun:test";
import type { AcpmuxRow } from "./model";
import { textBesideOneRow, textOnlyRow, textOnlyRowPast } from "./streamingRow";

const prompt: AcpmuxRow = { id: "p", version: 1, at: 0, kind: "user", text: "go" };
const reply = (text: string, version: number): AcpmuxRow => ({
  id: "r",
  version,
  at: 1,
  kind: "assistant",
  text,
  streaming: true,
});
const tool = (output: string, version: number): AcpmuxRow => ({
  id: "t",
  version,
  at: 2,
  kind: "tool",
  text: output,
});

test("a chunk after a command's output went to its own store is still only text", () => {
  const drawn = [prompt, reply("Hel", 1), tool("a", 1)];
  // The command's output grew: liveToolOutput.ts took it, the pane kept `drawn`.
  const received = [prompt, drawn[1]!, tool("a\nb", 2)];
  const next = [prompt, reply("Hello", 2), received[2]!];
  expect(textOnlyRow(drawn, next)).toBe(-1);
  expect(textOnlyRowPast(drawn, received, next)).toBe(1);
});

test("a chunk after an earlier chunk that was also let through compares against the drawn row", () => {
  const drawn = [prompt, reply("H", 1), tool("a", 1)];
  const received = [prompt, reply("Hel", 2), tool("a\nb", 2)];
  const next = [prompt, reply("Hello", 3), received[2]!];
  expect(textOnlyRowPast(drawn, received, next)).toBe(1);
});

test("a reply that rewrote what the pane drew, or a changed field, or a new row still redraws", () => {
  const drawn = [prompt, reply("Hey", 1), tool("a", 1)];
  const received = [prompt, drawn[1]!, tool("a\nb", 2)];
  expect(textOnlyRowPast(drawn, received, [prompt, reply("Hello", 2), received[2]!])).toBe(-1);
  const finished = { ...reply("Heyo", 2), streaming: false };
  expect(textOnlyRowPast(drawn, received, [prompt, finished, received[2]!])).toBe(-1);
  const cut = { ...reply("Heyo", 2), textComplete: true };
  expect(textOnlyRowPast(drawn, received, [prompt, cut, received[2]!])).toBe(-1);
  const grown = [prompt, reply("Heyo", 2), received[2]!, tool("c", 1)];
  expect(textOnlyRowPast(drawn, [...received, grown[3]!], grown)).toBe(-1);
  // The command's output and the reply in one snapshot: two rows changed since `received`.
  expect(textOnlyRowPast(drawn, received, [prompt, reply("Heyo", 2), tool("a\nb\nc", 3)])).toBe(-1);
});

test("a command's output and the reply's next chunk in one snapshot name the reply and the other row", () => {
  const drawn = [prompt, tool("a", 1), reply("Hel", 1)];
  const next = [prompt, tool("a\nb", 2), reply("Hello", 2)];
  expect(textOnlyRow(drawn, next)).toBe(-1);
  expect(textBesideOneRow(drawn, drawn, next)).toEqual({ at: 2, other: 1 });
  // After that snapshot went to the stores, the next pair compares the reply with the drawn row.
  const later = [prompt, tool("a\nb\nc", 3), reply("Hello there", 3)];
  expect(textBesideOneRow(drawn, next, later)).toEqual({ at: 2, other: 1 });
});

test("three changed rows, a rewritten reply, or no other change is not text beside one row", () => {
  const drawn = [prompt, tool("a", 1), reply("Hel", 1)];
  const three = [{ ...prompt, text: "go!" }, tool("a\nb", 2), reply("Hello", 2)];
  expect(textBesideOneRow(drawn, drawn, three)).toBeUndefined();
  expect(textBesideOneRow(drawn, drawn, [prompt, tool("a\nb", 2), reply("Hey", 2)])).toBeUndefined();
  expect(textBesideOneRow(drawn, drawn, [prompt, drawn[1]!, reply("Hello", 2)])).toBeUndefined();
  // The reply drawn as "Hey" and since rewritten: not grown from what the pane drew.
  const received = [prompt, tool("a", 1), reply("Hel", 2)];
  expect(
    textBesideOneRow([prompt, tool("a", 1), reply("Hey", 1)], received, [prompt, tool("a\nb", 2), reply("Hello", 3)]),
  ).toBeUndefined();
});
