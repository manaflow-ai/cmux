// The agent pane's controls are small-radius rects, not capsule pills (POLISH.md: "No capsule
// pills. Use small-radius rects. Circles must be truly round."). Reads the shipped page's one
// <style> and fails on a rule whose corner radius reaches half its height on a box that is not
// square, or that rounds with a 999px radius. Tracks and bars that are capsules by nature are
// listed below with why.
//
// The page is the built resource (CI builds the web bundles before this suite; locally run
// scripts/cmux-next/build-agent-pane-web.sh first).
import { describe, expect, test } from "bun:test";
import fs from "node:fs";
import path from "node:path";

const page = path.resolve(
  import.meta.dir,
  "../../Packages/macOS/CmuxNext/Sources/CmuxNextAgentPane/Resources/agent-pane/index.html",
);
const built = fs.existsSync(page);
if (!built && process.env.CI) throw new Error(`agent-pane-no-capsules: ${page} is not built`);
if (!built) console.warn("agent-pane-no-capsules: skipping (run scripts/cmux-next/build-agent-pane-web.sh)");

/** Capsules by nature: a toggle's track, a slider's track and fill, a progress bar, and drawn lines.
 * The composer's model, effort and access chips are small-radius rects again (Leo 2026-10-19). */
const SHAPES = new Set([
  ".acpmux-switch",
  ".acpmux-effort-track",
  ".acpmux-effort-fill",
  ".acpmux-context-bar",
  ".acpmux-pdf-sheet-lines i",
]);

const px = (value: string | undefined) => (value && /^-?[\d.]+px$/.test(value) ? parseFloat(value) : undefined);

/** Each selector's last border-radius, height and width, in source order. */
function boxes(css: string) {
  const found = new Map<string, { radius?: string; height?: string; width?: string }>();
  const plain = css.replace(/\/\*[\s\S]*?\*\//g, "");
  for (const [, selectors, body] of plain.matchAll(/([^{}@;]+)\{([^{}]*)\}/g)) {
    const declared = (property: string) =>
      [...body!.matchAll(new RegExp(`(?:^|;)\\s*${property}\\s*:\\s*([^;!]+)`, "g"))].at(-1)?.[1]?.trim();
    const radius = declared("border-radius");
    const height = declared("height");
    const width = declared("width");
    if (!radius && !height && !width) continue;
    for (const selector of selectors!.split(/,(?![^(]*\))/).map((part) => part.trim().replace(/\s+/g, " "))) {
      const box = found.get(selector) ?? {};
      found.set(selector, {
        radius: radius ?? box.radius,
        height: height ?? box.height,
        width: width ?? box.width,
      });
    }
  }
  return found;
}

describe.skipIf(!built)("agent pane page", () => {
  test("rounds its controls as small-radius rects, not capsules", () => {
    const html = fs.readFileSync(page, "utf8");
    const css = html.slice(html.indexOf("<style>") + "<style>".length, html.indexOf("</style>"));
    const capsules = [...boxes(css)].flatMap(([selector, box]) => {
      if (SHAPES.has(selector)) return [];
      const radius = px(box.radius?.split(/\s+/)[0]);
      const height = px(box.height);
      const width = px(box.width);
      if (radius === undefined) return [];
      const square = height !== undefined && width !== undefined && Math.abs(width - height) < 1;
      const capsule = radius >= 999 || (height !== undefined && !square && radius >= height / 2 - 0.5);
      return capsule ? [`${selector} (radius ${box.radius}, height ${box.height ?? "auto"})`] : [];
    });
    expect(capsules).toEqual([]);
  });
});
