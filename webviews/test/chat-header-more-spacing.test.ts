// The chat menu's ⋮ sits as close to the tool before it as the other tools sit to each other (Leo 2026-11-03: "i
// don't like how this vertical ellipsis looks spaced next to everything else"). Its dots are about 3px wide, so in
// the 24px box the other tools take they left about 18px of empty space before them where every other glyph leaves
// about 13px. Its box is its 16px glyph box (24px tall, as the others) and the 8px it gives up stays at its trailing
// side, so the row keeps its width. The gallery's agent-pane.header-tools/more-* variants measure it in a browser.
import { expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import { join } from "node:path";

const HEADER = join(import.meta.dir, "../src/agent-session/acpmux/header");
const css = readFileSync(join(HEADER, "header.css"), "utf8").replace(/\/\*[\s\S]*?\*\//g, "");

function declarations(selector: string): Map<string, string> {
  const escaped = selector.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
  const match = css.match(new RegExp(`(?:^|\\})\\s*${escaped}\\s*\\{([^{}]*)\\}`, "m"));
  expect(match, `header.css has a rule for ${selector}`).toBeTruthy();
  return new Map(
    match![1]!
      .split(";")
      .map((part) => part.split(":").map((side) => side.trim()))
      .filter((pair): pair is [string, string] => pair.length === 2 && pair[0] !== ""),
  );
}

const px = (value: string | undefined) => Number(/^(\d+(?:\.\d+)?)px$/.exec(value ?? "")?.[1] ?? Number.NaN);

test("the chat menu's trigger carries the ⋮ class by default", () => {
  const source = readFileSync(join(HEADER, "ChatHeaderTools.tsx"), "utf8");
  expect(source).toContain('className={triggerClassName ?? "acpmux-header-tool acpmux-header-more"}');
});

test("the ⋮ box is its glyph box wide, as tall as a tool, and keeps the row's width", () => {
  const tool = declarations(".acpmux-header-tool");
  const more = declarations(".acpmux-header-tool.acpmux-header-more");
  const side = px(tool.get("width"));
  expect(side).toBe(24);
  expect(px(tool.get("height"))).toBe(side);
  // 16: HEADER_GLYPH, the glyph box every tool draws its icon in.
  expect(px(more.get("width"))).toBe(16);
  expect(more.has("height")).toBe(false);
  // The width it gives up stays at its trailing side: the row (and the tabs beside it) does not move.
  expect(px(more.get("width")) + px(more.get("margin-inline-end"))).toBe(side);
});

test("centre to centre, the ⋮ sits 22px after a tool, against the 26px pitch between tools", () => {
  const gap = px(declarations(".acpmux-header-tools").get("gap"));
  const side = px(declarations(".acpmux-header-tool").get("width"));
  const more = px(declarations(".acpmux-header-tool.acpmux-header-more").get("width"));
  expect(side + gap).toBe(26);
  expect(side / 2 + gap + more / 2).toBe(22);
  // The ⋮'s dots (about 3px of its 16px glyph box) then start as far from the tool before them as the next
  // glyph starts after the one before it, within 2px: (16 - 3) / 2 + (22 - 16 / 2 - 24 / 2) against 24 - 16 + gap.
  const dots = 3;
  const before = (16 - dots) / 2 + (side / 2 + gap + more / 2 - 16 / 2 - side / 2);
  expect(Math.abs(before - (side - 16 + gap))).toBeLessThanOrEqual(2);
});
