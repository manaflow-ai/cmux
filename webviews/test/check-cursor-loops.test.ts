// The cursor-loop rule (scripts/check-cursor-loops.ts): every `while (`, `do {` and `for (;;)` in direct.ts and the
// row model says why it ends (`// ends: <reason>`), so a loop like shedOlderHeld's span loop, which found the same cut
// again and spun Leo's renderer at 100% CPU, cannot come back unread.
import { expect, test } from "bun:test";
import { findAllUnprovedLoops, findUnprovedLoops } from "../scripts/check-cursor-loops";

test("every loop in direct.ts and the row model says why it ends", () => {
  expect(findAllUnprovedLoops().map((f) => `${f.file}:${f.line} ${f.text}`)).toEqual([]);
});

test("a loop with no ends: marker is flagged; a marked one, prose and a do-while's tail are not", () => {
  const source = [
    "function spin(events: number[], from: number) {", // 1
    "  let cut = events.length;", // 2
    "  while (cut > 0) {", // 3: flagged
    "    cut = events.indexOf(from);", // 4
    "  }", // 5
    "  // The cut goes back to where its row begins.", // 6
    "  // ends: `cut` falls by one each pass, to 0 at most", // 7
    "  while (cut > 0) cut -= 1;", // 8: marked in the comment block above
    "  for (;;) {", // 9: flagged
    "    if (cut === 0) break;", // 10
    "  }", // 11
    "  do {", // 12: flagged once, not again at its tail
    "    cut += 1;", // 13
    "  } while (cut < 3);", // 14
    "  for (;;) break; // ends: breaks at once", // 15: marked on its own line
    "  /// A while (true) in prose is not a loop.", // 16
    "  const note = 1; // loops while (x) here", // 17
    "  while (cut > 0) {", // 18: flagged: the marker two lines up is past a code line
    "    cut -= 1;", // 19
    "  }", // 20
    "}", // 21
  ].join("\n");
  expect(findUnprovedLoops("fixture.ts", source).map((f) => `${f.line} ${f.text}`)).toEqual([
    "3 while (cut > 0) {",
    "9 for (;;) {",
    "12 do {",
    "18 while (cut > 0) {",
  ]);
});

test("a `while (` in a string or a template literal is no loop", () => {
  const source = [
    'const a = "while (true) {";', // 1
    "const b = `do { spin(); } while (x); for (;;) {`;", // 2
    "const c = `${'while (y)'} and ${a}`;", // 3
    "const d = { for: 1, while: 2 }.while;", // 4
  ].join("\n");
  expect(findUnprovedLoops("fixture.ts", source)).toEqual([]);
});

test("a loop header split over lines is a loop, read at its first line", () => {
  const source = [
    "function f(items: number[]) {", // 1
    "  let i = 0;", // 2
    "  while (", // 3: flagged
    "    i < items.length &&", // 4
    "    items[i]! > 0", // 5
    "  ) i += 1;", // 6
    "  for (", // 7: flagged: a for with no condition
    "    let j = 0;", // 8
    "    ;", // 9
    "    j += 1", // 10
    "  ) if (j > 3) break;", // 11
    "  // ends: `i` grows by one each pass, to items.length at most", // 12
    "  while (", // 13: marked
    "    i < items.length", // 14
    "  ) i += 1;", // 15
    "}", // 16
  ].join("\n");
  expect(findUnprovedLoops("fixture.ts", source).map((f) => `${f.line} ${f.text}`)).toEqual(["3 while (", "7 for ("]);
});

test("a do/while is one loop, flagged once at its `do` and proved by a marker above it", () => {
  const unmarked = ["let n = 0;", "do {", "  n += 1;", "} while (n < 3);"].join("\n");
  expect(findUnprovedLoops("fixture.ts", unmarked).map((f) => `${f.line} ${f.text}`)).toEqual(["2 do {"]);
  const marked = ["let n = 0;", "// ends: `n` grows by one each pass, to 3", "do n += 1;", "while (n < 3);"].join("\n");
  expect(findUnprovedLoops("fixture.ts", marked)).toEqual([]);
});

test("a counted for loop is no cursor loop; a marker in a string proves nothing", () => {
  const source = [
    "for (let i = 0; i < 3; i += 1) {}", // 1: has a condition
    'while (go()) say("// ends: never");', // 2: flagged: the marker is in a string
  ].join("\n");
  expect(findUnprovedLoops("fixture.ts", source).map((f) => `${f.line} ${f.text}`)).toEqual([
    '2 while (go()) say("// ends: never");',
  ]);
});
