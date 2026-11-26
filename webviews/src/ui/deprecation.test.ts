import { afterEach, expect, test } from "bun:test";
import { noteDeprecated, resetDeprecationWarningsForTests, warnDeprecated } from "./deprecation";

afterEach(resetDeprecationWarningsForTests);

test("a deprecated name warns once, naming its replacement", () => {
  const lines: string[] = [];
  noteDeprecated("OldThing", "NewThing", (line) => lines.push(line));
  noteDeprecated("OldThing", "NewThing", (line) => lines.push(line));
  noteDeprecated("OtherThing", "Better", (line) => lines.push(line));
  expect(lines).toEqual([
    "cmux ui: OldThing is deprecated. Use NewThing instead (webviews/src/ui/STATUS.md).",
    "cmux ui: OtherThing is deprecated. Use Better instead (webviews/src/ui/STATUS.md).",
  ]);
});

test("outside a dev build warnDeprecated says nothing", () => {
  const original = console.warn;
  const lines: unknown[] = [];
  console.warn = (...args: unknown[]) => void lines.push(args);
  try {
    expect(Boolean(import.meta.env?.DEV)).toBe(false);
    warnDeprecated("OldThing", "NewThing");
  } finally {
    console.warn = original;
  }
  expect(lines).toEqual([]);
});
