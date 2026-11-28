// The pages' hover intent (ui/hoverIntent.ts, HOVER_INTENT) and the native app's
// (CmuxNextDesign HoverIntentTiming.standard, and the Motion tunables' defaults) are one policy in
// two languages: a tooltip in a page and one in the app wait the same and stay warm the same.
import { expect, test } from "bun:test";
import fs from "node:fs";
import path from "node:path";
import { HOVER_INTENT } from "../src/ui/hoverIntent";

const design = path.resolve(import.meta.dir, "../../Packages/macOS/CmuxNext/Sources/CmuxNextDesign");
const read = (file: string) => fs.readFileSync(path.join(design, file), "utf8");

test("the pages' hover timing matches the native app's", () => {
  const swift = read("HoverIntent/HoverIntent.swift");
  const standard = swift.slice(swift.indexOf("static let standard"));
  const ms = (name: string) => {
    const match = new RegExp(`${name}: \\.milliseconds\\(([\\d_]+)\\)`).exec(standard);
    expect(match, `${name} in HoverIntentTiming.standard`).not.toBeNull();
    return Number(match![1].replaceAll("_", ""));
  };
  const native = {
    tooltipDelay: ms("tooltipDelay"),
    tooltipWarm: ms("tooltipWarm"),
    cardGrace: ms("cardGrace"),
    cardAim: ms("cardAim"),
  };
  // cardDwell is the pages' own: the native workspace and tab cards wait Chrome's delay or the
  // user's sidebar.hoverCards.delay (HoverCardTiming.swift).
  const { cardDwell: _pagesOnly, ...shared } = HOVER_INTENT;
  expect(native).toEqual(shared);

  // The tunables default to the same values (seconds).
  const tunables = read("Motion/MotionTunables.swift");
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
