// The composer hat takes its columns from the composer's own tokens, with nothing added (cmux#56151).
// Its leading column starts at the composer's inset and each mark centres itself in a lead box the
// composer's control wide, so the mark centres on + and the words start one lead gap after it, where
// the prompt's do. A second offset on top (the retired `glyph` column: the inset plus half of what the
// control is wider than the glyph) put the plan bar's Claude mark right of the + and its words right
// of the placeholder. test/composer-stack-columns.test.ts measures the result in Chromium; this file
// holds the token contract on every host, so the offset cannot come back unseen.
import { describe, expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import path from "node:path";

const css = readFileSync(
  path.resolve(import.meta.dir, "../src/agent-session/acpmux/subagents/subagents.css"),
  "utf8",
).replace(/\/\*[\s\S]*?\*\//g, "");

/** Every value a custom property is declared with in the sheet. */
const declared = (name: string) =>
  [...css.matchAll(new RegExp(`${name}:\\s*([^;]+);`, "g"))].map((match) => match[1]!.replace(/\s+/g, " ").trim());

describe("the composer hat's columns come from the composer's tokens", () => {
  test("the leading column starts at the composer's inset, never past it", () => {
    expect(declared("--acpmux-tray-inset-start")).toEqual(["var(--acpmux-tray-inset)"]);
    expect(declared("--acpmux-tray-inset")).toEqual([
      "var(--acpmux-composer-inset, calc(8px * var(--cmux-interface-scale, 1)))",
    ]);
  });

  test("the lead box is the composer's control, the words one composer lead gap after it", () => {
    expect(declared("--acpmux-tray-lead-box")).toEqual(["var(--acpmux-composer-control, 28px)"]);
    expect(declared("--acpmux-tray-lead-gap")).toEqual(["var(--acpmux-composer-lead-gap, 8px)"]);
  });

  test("a mark centres in the lead box by its own size's room", () => {
    expect(declared("--acpmux-tray-lead-room")).toEqual([
      "calc((var(--acpmux-tray-lead-box) - var(--acpmux-tray-glyph)) / 2)",
    ]);
    // A harness mark keeps the faces' size at every density, so it takes that size's room.
    expect(declared("--acpmux-tray-mark-room")).toEqual([
      "calc((var(--acpmux-tray-lead-box) - var(--acpmux-tray-face)) / 2)",
    ]);
    const stack = css.match(/\.acpmux-running-tray__head > \.acpmux-running-tray__stack \{([^}]*)\}/)?.[1] ?? "";
    expect(stack).toContain("var(--acpmux-tray-mark-room)");
  });

  test("no column arm shifts the hat off the composer's columns", () => {
    expect(css).not.toContain("data-column");
  });
});
