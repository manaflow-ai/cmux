// The pages' hover intent (ui/hoverIntent.ts, HOVER_INTENT) and the native app's (cmux-motion's
// HoverIntentTiming::STANDARD, which the app reads through its C ABI, and the Motion tunables'
// defaults) are one policy in two languages: a tooltip in a page and one in the app wait the same
// and stay warm the same.
import { expect, test } from "bun:test";
import fs from "node:fs";
import path from "node:path";
import { HOVER_INTENT } from "../src/ui/hoverIntent";

const repo = path.resolve(import.meta.dir, "../..");
const sources = path.join(repo, "Packages/macOS/CmuxNext/Sources");
let files: string[] | undefined;
// By file name under Sources, not by target folder: the architecture refactor moves files between
// targets (72673e48762 moved both into CmuxNextDesignTokens while this test still read
// CmuxNextDesign, so it failed with ENOENT). One major type per file keeps each name unique.
const read = (name: string) => {
  files ??= fs.readdirSync(sources, { recursive: true, encoding: "utf8" });
  const found = files.filter((file) => path.basename(file) === name);
  expect(found, `exactly one ${name} under ${sources}`).toHaveLength(1);
  return fs.readFileSync(path.join(sources, found[0]!), "utf8");
};

test("the pages' hover timing matches the native app's", () => {
  const rust = fs.readFileSync(path.join(repo, "cmux-tui/crates/cmux-motion/src/hover/timing.rs"), "utf8");
  const standard = rust.slice(rust.indexOf("pub const STANDARD"));
  const ms = (name: string) => {
    const match = new RegExp(`${name}: millis\\(([\\d_]+)\\)`).exec(standard);
    expect(match, `${name} in HoverIntentTiming::STANDARD`).not.toBeNull();
    return Number(match![1].replaceAll("_", ""));
  };
  const native = {
    tooltipDelay: ms("tooltip_delay"),
    tooltipWarm: ms("tooltip_warm"),
    cardGrace: ms("card_grace"),
    cardAim: ms("card_aim"),
  };
  // cardDwell is the pages' own: the native workspace and tab cards wait Chrome's delay or the
  // user's sidebar.hoverCards.delay (cmux-motion hover/timing.rs, HOVER_CARD_SHOW_DELAY).
  const { cardDwell: _pagesOnly, ...shared } = HOVER_INTENT;
  expect(native).toEqual(shared);

  // The tunables default to the same values (seconds).
  const tunables = read("MotionTunables.swift");
  const seconds = (key: string) => {
    const match = new RegExp(`"${key.replaceAll(".", "\\.")}"[\\s\\S]*?default: ([\\d.]+)`).exec(tunables);
    expect(match, key).not.toBeNull();
    return Math.round(Number(match![1]) * 1000);
  };
  expect({
    tooltipDelay: seconds("motion.tooltip.delay"),
    tooltipWarm: seconds("motion.tooltip.warm"),
    cardGrace: seconds("motion.hoverCard.grace"),
    cardAim: seconds("motion.hoverCard.aim"),
  }).toEqual(shared);
});
