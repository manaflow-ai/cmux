// The agent pane's controls are small-radius rects, not capsule pills (POLISH.md: "No capsule
// pills. Use small-radius rects. Circles must be truly round."). Reads the shipped page's one
// <style> and fails on a rule whose corner radius reaches half its height on a box that is not
// square, including a 999px radius on a box without explicit square dimensions. Tracks and bars that are capsules by nature are
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

/** Capsules by nature: a toggle's track, a slider's track and fill, a progress bar, drawn lines,
 * and the composer's model, effort and access chips, whose hover, focus and open background is the
 * Claude app's soft pill (#22107; composer-chip-plain-rest and composer-chip-press check it). The
 * Cards New Tab template (u2851, from the user's scrawl of Aside's New Tab page) is a pill design
 * on purpose: its field and its selected Chats tab are round (newtab/screen.css). The other templates keep small-radius rects. */
const SHAPES = new Set([
  ".acpmux-switch",
  ".acpmux-quick-fast-toggle",
  ".acpmux-effort-track",
  ".acpmux-effort-fill",
  ".acpmux-context-card-bar",
  ".acpmux-chat-inspector-context__bar",
  // The workflow card's progress bar and its phase segments (4ad2cc9c8eff, #27019): 4 px bars.
  ".acpmux-workflow-card__progress",
  ".acpmux-workflow-card__phases > span",
  ".acpmux-pdf-sheet-lines i",
  ":is(.acpmux-composer-bar,.nt-pickers) .acpmux-model .acpmux-picker-button",
  ":is(.acpmux-composer-bar,.nt-pickers) .acpmux-effort .acpmux-picker-button",
  ":is(.acpmux-composer-bar,.nt-pickers) .acpmux-access .acpmux-picker-button",
  ".acpmux-model .acpmux-picker-button",
  ".acpmux-effort .acpmux-picker-button",
  ".acpmux-access .acpmux-picker-button",
  '.nt-screen[data-template="cards"][data-pill] .nt-box',
  '.nt-screen[data-template="cards"] .nt-chats-tab.is-selected',
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
    for (const selector of selectors!.split(/,(?![^(]*\))/).map((part) =>
      part
        .trim()
        .replace(/\s+/g, " ")
        .replace(/\s*,\s*/g, ","),
    )) {
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

function capsules(css: string) {
  return [...boxes(css)].flatMap(([selector, box]) => {
    if (SHAPES.has(selector)) return [];
    const radius = px(box.radius?.split(/\s+/)[0]);
    const height = px(box.height);
    const width = px(box.width);
    if (radius === undefined) return [];
    const square = height !== undefined && width !== undefined && Math.abs(width - height) < 1;
    const capsule = !square && (radius >= 999 || (height !== undefined && radius >= height / 2 - 0.5));
    return capsule ? [`${selector} (radius ${box.radius}, height ${box.height ?? "auto"})`] : [];
  });
}

describe("capsule detection", () => {
  test.each([
    ["a circle", ".control { width: 32px; height: 32px; border-radius: 999px; }", false],
    ["a small-radius rectangle", ".control { width: 60px; height: 24px; border-radius: 4px; }", false],
    ["a fully rounded rectangle", ".control { width: 60px; height: 24px; border-radius: 999px; }", true],
    ["a half-height radius", ".control { width: 60px; height: 24px; border-radius: 12px; }", true],
    ["an auto-height pill", ".control { border-radius: 999px; }", true],
    ["a toggle track", ".acpmux-quick-fast-toggle { width: 30px; height: 20px; border-radius: 999px; }", false],
  ])("classifies %s", (_name, css, expected) => {
    expect(capsules(css).length > 0).toBe(expected);
  });
});

describe.skipIf(!built)("agent pane page", () => {
  test("rounds its controls as small-radius rects, not capsules", () => {
    const html = fs.readFileSync(page, "utf8");
    const css = html.slice(html.indexOf("<style>") + "<style>".length, html.indexOf("</style>"));
    expect(capsules(css)).toEqual([]);
  });
});
