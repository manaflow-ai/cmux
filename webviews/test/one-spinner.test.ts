// ONE SPINNER (Leo 2026-11-02: "WHY THE F*** IS THE SPINNER ON THE RUNNING SO F***ING FAST SLOW IT DOWN
// AND WHY THE F*** ARE YOU GUYS POSSIBLY DIFFERING THE F***ING SPINNERS ACROSS THE SIDEBAR AND THE
// F***ING RUNNING"). Every spinner is one component: on the web `Spinner` (agent-session/acpmux/
// conversation/icons.tsx, `cv-spinner`, turned by spinner.css), natively `StatusIndicatorView` /
// `StatusIndicatorLayer` (CmuxNextDesign/StatusIndicator), and both draw the same thin 3/4 arc
// (StatusIndicatorPlan.workingGlyph; Leo 2026-11-03 on the original arc: "we can keep that"). This fails when a surface draws a spinner of its own: a CSS rule
// that turns something other than `cv-spinner` on the spinner keyframes, a page component that writes
// the keyframes inline, or native code that builds its own turning indicator.
import { readdirSync, readFileSync } from "node:fs";
import path from "node:path";
import { expect, test } from "bun:test";

const webviews = path.resolve(import.meta.dir, "..");
const src = path.join(webviews, "src");
const nativeSources = path.resolve(webviews, "../Packages/macOS/CmuxNext/Sources");

function files(dir: string, keep: (file: string) => boolean): string[] {
  return readdirSync(dir, { recursive: true, withFileTypes: true })
    .filter((entry) => entry.isFile())
    .map((entry) => path.join(entry.parentPath, entry.name))
    .filter(keep);
}

/** Spinners that are not the shared component, each with why it may stay. Keep this list short. */
const CSS_ALLOWED: Record<string, string> = {
  // The diff viewer is its own page outside the agent pane (styles.css): a pseudo-element status
  // line and a branch-picker button while the page navigates, not a working mark.
  "styles.css .base-picker-spinner": "diff viewer page loading",
  'styles.css #status[data-pending="true"]::before, body[data-loading="true"] #status::before':
    "diff viewer page loading",
};

test("on the web only `cv-spinner` turns on the spinner keyframes", () => {
  const found: string[] = [];
  for (const file of files(src, (name) => name.endsWith(".css"))) {
    // Rules only (comments out), flattened so a selector and its block read as one.
    const css = readFileSync(file, "utf8").replace(/\/\*[\s\S]*?\*\//g, "");
    for (const match of css.matchAll(/([^{}]+)\{([^{}]*)\}/g)) {
      const [, selector, block] = match;
      if (!/animation(-name)?\s*:[^;]*\bcmux-spin\b/.test(block)) continue;
      const clean = selector.trim().replace(/\s+/g, " ");
      if (/(^|[\s,>+~])\.cv-spinner\b/.test(clean) || /\.cv-spinner(\[|:|\s|$)/.test(clean)) continue;
      found.push(`${path.relative(src, file)} ${clean}`);
    }
  }
  expect(found.filter((rule) => !(rule in CSS_ALLOWED))).toEqual([]);
});

test("no page component writes the spinner keyframes itself", () => {
  const allowed = new Set(["ui/spinnerClock.ts", "pages/shared/desktop.ts"]);
  const found = files(src, (name) => /\.(ts|tsx)$/.test(name) && !/\.(test|gallery)\.tsx?$/.test(name))
    .filter((file) => !allowed.has(path.relative(src, file)))
    .filter((file) => /["'`]cmux-spin\b|animation\s*:\s*["'`][^"'`]*\bcmux-spin\b/.test(readFileSync(file, "utf8")))
    .map((file) => path.relative(src, file));
  expect(found).toEqual([]);
});

test("natively every spinner is the shared StatusIndicator", () => {
  // Inside CmuxNextDesign the indicator and the motion gate own the turning animations.
  const owners = [
    path.join(nativeSources, "CmuxNextDesign/StatusIndicator"),
    path.join(nativeSources, "CmuxNextDesign/Motion"),
    path.join(nativeSources, "CmuxNextDesignTokens"),
  ];
  const own = [
    /\bNSProgressIndicator\s*\(/,
    /\.spinningStyle\b/,
    /\bspinAnimation\s*\(/,
    /\bstepAnimation\s*\(/,
    /\.progressViewStyle\(\s*\.circular\s*\)/,
    // SwiftUI's indeterminate ProgressView is the macOS spinner unless it is styled as a bar.
    /\bProgressView\s*\(\s*\)(?!\s*\.progressViewStyle\(\s*\.linear\s*\))/,
  ];
  const found: string[] = [];
  for (const file of files(nativeSources, (name) => name.endsWith(".swift"))) {
    if (owners.some((owner) => file.startsWith(owner + path.sep))) continue;
    const lines = readFileSync(file, "utf8").split("\n");
    lines.forEach((line, index) => {
      if (/^\s*\/\//.test(line)) return;
      if (own.some((pattern) => pattern.test(line))) found.push(`${path.relative(nativeSources, file)}:${index + 1}`);
    });
  }
  expect(found).toEqual([]);
  // Reads every CmuxNext Swift source, which takes about 5 s on a busy host.
}, 30_000);

test("the loading glyph is the working arc, natively too", () => {
  const plan = readFileSync(
    path.join(nativeSources, "CmuxNextDesign/StatusIndicator/StatusIndicatorPlan.swift"),
    "utf8",
  );
  // The default (arc) loading style turns the same glyph agent work does.
  expect(plan).toMatch(
    /case \.arc: return StatusIndicatorPlan\(glyph: workingGlyph, animation: \.spin, tint: \.loading\)/,
  );
});
