// Every hover card waits the same Chrome delay (Lawrence 2026-11-15: "copy chrome's delay exactly
// ... make sure it is consistent between every thing"). The numbers live in one place per language:
// HoverIntentTiming (Packages/macOS/CmuxNext/Sources/CmuxNextDesignTokens/HoverIntent/HoverIntent.swift)
// and HOVER_INTENT (src/ui/hoverIntent.ts); hover-intent-parity.test.ts keeps the two equal. This test
// fails when a hover card source writes a delay of its own instead of reading them. A duration that
// is not a show or hide delay (a pinned card's lifetime, a corridor cap) says so on its line or the
// line above with `hover-timing: <why>`.
import { expect, test } from "bun:test";
import fs from "node:fs";
import path from "node:path";

const root = path.resolve(import.meta.dir, "../..");
const swiftRoot = path.join(root, "Packages/macOS/CmuxNext/Sources");
const webRoot = path.join(root, "webviews/src");
const swiftSource = "CmuxNextDesignTokens/HoverIntent/HoverIntent.swift";
const webSource = "ui/hoverIntent.ts";

const list = (dir: string, ext: RegExp) =>
  fs
    .readdirSync(dir, { recursive: true, encoding: "utf8" })
    .filter((file) => ext.test(file) && !/\.(test|gallery|bench)\./.test(file));

/** Lines with a literal duration that carry no `hover-timing:` reason (on the line or the one above). */
function unexplained(text: string, literal: RegExp) {
  const lines = text.split("\n");
  return lines.flatMap((line, i) => {
    if (!literal.test(line) || line.trimStart().startsWith("//")) return [];
    if (/hover-timing:/.test(line) || /hover-timing:/.test(lines[i - 1] ?? "")) return [];
    return [`${i + 1}: ${line.trim()}`];
  });
}

test("no native hover card has a delay of its own", () => {
  const isCardSource = (file: string, text: string) =>
    /(^|\/)HoverCards\//.test(file) || /HoverTarget\(|presentOwned\(|HoverCardMachine\(/.test(text);
  // Duration literals (`.milliseconds(400)`, `Duration.seconds(1)`, ...) and GCD/TimeInterval waits.
  const literal =
    /\.(milliseconds|microseconds|nanoseconds|seconds)\(\s*[\d_.]+\s*\)|\.now\(\)\s*\+\s*[\d.]+|(after|delay|Delay|interval|Interval):\s*[\d.]+\b/;
  const files = list(swiftRoot, /\.swift$/).filter((file) => file !== swiftSource);
  const found = files.flatMap((file) => {
    const text = fs.readFileSync(path.join(swiftRoot, file), "utf8");
    if (!isCardSource(file, text)) return [];
    return unexplained(text, literal).map((line) => `${file}:${line}`);
  });
  // The scan reads the sources it should: the row, rail, tab, pull request and update cards.
  expect(
    files.filter((file) => isCardSource(file, fs.readFileSync(path.join(swiftRoot, file), "utf8"))).length,
  ).toBeGreaterThan(10);
  expect(found, "read HoverIntentTiming (cardDelay, cardReshow, cardGrace) or DesignSettings.hoverCardDelay").toEqual(
    [],
  );
});

test("no page hover card has a delay of its own", () => {
  const isCardSource = (file: string, text: string) =>
    /hover-?card|updatedPreview|sessionHover|threadMinimap/i.test(file) ||
    /useHoverCard\(|useHoverIntent(<[^>]*>)?\(|new HoverGroup\(|new HoverIntent(<[^>]*>)?\(/.test(text);
  // A named delay constant or a delay argument written as a number.
  const literal =
    /\b[A-Z_]*(DWELL|DELAY|GRACE)[A-Z_]*\s*=\s*[\d_]+\b|\b(dwell|delay|grace)\s*:\s*[\d_]+\b|useHoverCard\(\s*[\d_]+/;
  const files = list(webRoot, /\.tsx?$/).filter((file) => file !== webSource);
  const found = files.flatMap((file) => {
    const text = fs.readFileSync(path.join(webRoot, file), "utf8");
    if (!isCardSource(file, text)) return [];
    return unexplained(text, literal).map((line) => `${file}:${line}`);
  });
  expect(found, "read HOVER_INTENT (cardDwell, cardGrace, tooltipDelay)").toEqual([]);
});
