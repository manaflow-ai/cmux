// The cursor-loop rule (scripts/check-cursor-loops.ts): every `while (`, `do {` and `for (;;)` in direct.ts and the
// row model says why it ends (`// ends: <reason>`), so a loop like shedOlderHeld's span loop, which found the same cut
// again and spun Leo's renderer at 100% CPU, cannot come back unread.
import { expect, test } from "bun:test";
import { findAllUnprovedLoops, findUnprovedLoops, KNOWN_OPEN } from "../scripts/check-cursor-loops";

test("every loop in direct.ts and the row model says why it ends", () => {
  const found = findAllUnprovedLoops();
  expect(found.filter((f) => !f.known).map((f) => `${f.file}:${f.line} ${f.text}`)).toEqual([]);
  // Only the loops KNOWN_OPEN names pass unmarked, at most one each.
  expect(found.length).toBeLessThanOrEqual(KNOWN_OPEN.length);
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

test("a known open loop is reported as known only where its body names it", () => {
  const entry = KNOWN_OPEN[0]!;
  const body = (inner: string) => ["    " + entry.loop, "      const { seq } = this.events[cut]!;", inner, "    }"];
  const named = findUnprovedLoops(entry.file, body("      " + entry.body).join("\n"));
  expect(named.map((f) => Boolean(f.known))).toEqual([true]);
  const other = findUnprovedLoops(entry.file, body("      cut -= 1;").join("\n"));
  expect(other.map((f) => Boolean(f.known))).toEqual([false]);
});
