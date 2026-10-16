import { expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import { join } from "node:path";

const css = readFileSync(join(import.meta.dir, "../src/agent-session/acpmux/threadMinimap/threadMinimap.css"), "utf8");

test("thread minimap keeps rest and current ticks at the measured reference contrast", () => {
  expect(css).toMatch(/\.acpmux-minimap__bar,\s*\.acpmux-minimap__dot\s*\{[\s\S]*?opacity: 0\.28;/);
  expect(css).toMatch(
    /\.acpmux-minimap__tick\[data-tone="current"\] \.acpmux-minimap__bar\s*\{[\s\S]*?opacity: 0\.48;/,
  );
  expect(css).toMatch(
    /\.acpmux-minimap__rail\[data-hovering\] \.acpmux-minimap__tick\[data-tone="current"\] \.acpmux-minimap__bar\s*\{[\s\S]*?opacity: 0\.28;/,
  );
});
