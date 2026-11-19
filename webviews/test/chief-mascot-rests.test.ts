// CMUX-672 (idle CPU, RAM and GPU to the minimum): the Chief dock's mascot floated forever, a compositor frame every
// refresh on a page where nothing changed (bench/idle-frame-sources.bench.ts: 55.9 drawn frames a second at rest),
// and its will-change held a layer. It now floats three times when the dock appears, then rests, and waits while the
// page is not the key one.
import { readFileSync } from "node:fs";
import path from "node:path";
import { expect, test } from "bun:test";

const css = readFileSync(path.resolve(import.meta.dir, "../src/agent-session/acpmux/styles.css"), "utf8");

/// The declarations of the first rule whose selector list is exactly `selector`.
function rule(selector: string): string {
  const at = css.indexOf(`${selector}{`);
  expect(at).toBeGreaterThanOrEqual(0);
  return css.slice(at + selector.length + 1, css.indexOf("}", at));
}

test("the mascot's float ends and holds no layer", () => {
  const mascot = rule(".acpmux-chief-dock-mascot img");
  const declarations = mascot.split(";");
  const shorthand = declarations.findIndex((line) => line.startsWith("animation:"));
  expect(declarations[shorthand]).toContain("acpmux-chief-mascot-float");
  // The longhands come after the shorthand, so they win over its count and fill.
  const last = (property: string) => declarations.findLastIndex((line) => line.startsWith(`${property}:`));
  expect(last("animation-iteration-count")).toBeGreaterThan(shorthand);
  expect(declarations[last("animation-iteration-count")]).toBe("animation-iteration-count:3");
  // It ends on its first frame's pose (0% and 100% are the same), held so it never jumps back.
  expect(last("animation-fill-mode")).toBeGreaterThan(shorthand);
  expect(declarations[last("animation-fill-mode")]).toBe("animation-fill-mode:forwards");
  expect(mascot).not.toContain("will-change");
});

test("the float waits while the page is not the key one", () => {
  expect(rule(":root[data-page-inactive] .acpmux-chief-dock-mascot img")).toContain("animation-play-state:paused");
});
