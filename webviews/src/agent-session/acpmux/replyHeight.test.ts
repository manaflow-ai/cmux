import { expect, test } from "bun:test";
import { replyHeight } from "./replyHeight";

// The whole-reply count it replaced: every line split out and summed.
const bySplit = (reply: string) => {
  const lines = reply.split("\n").reduce((sum, line) => sum + Math.max(1, Math.ceil(line.length / 60)), 0);
  return Math.min(lines, 3) * 16 + (lines > 3 ? 20 : 0);
};

test("replyHeight stops at the fourth wrapped line and matches the full count", () => {
  const cases = [
    "",
    "\n",
    "\n\n",
    "\n\n\n",
    "one line",
    "a\nb",
    "a\nb\nc",
    "a\nb\nc\n",
    "a\nb\nc\nd",
    "x".repeat(60),
    "x".repeat(61),
    "x".repeat(180),
    "x".repeat(181),
    `${"x".repeat(119)}\n${"y".repeat(60)}`,
    `${"x".repeat(120)}\n`,
    "é".repeat(59) + "\u{1F600}",
    "word ".repeat(20_000),
    "line\n".repeat(10_000),
  ];
  for (const reply of cases) expect(replyHeight(reply)).toBe(bySplit(reply));
  expect(replyHeight("a")).toBe(16);
  expect(replyHeight("a\nb\nc")).toBe(48);
  expect(replyHeight("a\nb\nc\nd")).toBe(68);
});

test("replyHeight matches the full count on random replies", () => {
  let seed = 7;
  const random = () => (seed = (seed * 1_103_515_245 + 12_345) % 2_147_483_648) / 2_147_483_648;
  for (let run = 0; run < 2_000; run++) {
    let reply = "";
    const parts = Math.floor(random() * 8);
    for (let part = 0; part < parts; part++) reply += random() < 0.4 ? "\n" : "z".repeat(Math.floor(random() * 130));
    expect(replyHeight(reply)).toBe(bySplit(reply));
  }
});
