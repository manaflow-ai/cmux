// ONE SPINNER (Leo 2026-11-02: "WHY THE F*** IS THE SPINNER ON THE RUNNING SO F***ING FAST SLOW IT DOWN
// AND WHY THE F*** ARE YOU GUYS POSSIBLY DIFFERING THE F***ING SPINNERS ACROSS THE SIDEBAR AND THE
// F***ING RUNNING", and "JUST DO THE CHATGPT SPINNER"). Every spinner is one component: on the web `Spinner`
// (agent-session/acpmux/conversation/Spinner.tsx, `cv-spinner`, turned by spinner.css), natively
// `StatusIndicatorView` / `StatusIndicatorLayer` (CmuxNextDesign/StatusIndicator), and both draw the same thin
// 3/4 arc (StatusIndicatorPlan.workingGlyph; Leo 2026-11-03 on the original arc: "we can keep that"). The
// agent-chat sidecar (agent-chat/src/components/icons.tsx `Spinner`) and cmux.com (web/app/components/spinner.tsx)
// each have one copy of that arc, as they cannot import the pages' component. `adHocSpinners()` lists every
// spinner drawn outside those components; it must stay empty: a CSS rule that turns something other than the
// component on the spinner keyframes, a page component that writes the keyframes inline, or native code that
// builds its own turning indicator.
import { readdirSync, readFileSync } from "node:fs";
import path from "node:path";
import { expect, test } from "bun:test";
import { SPINNER_PERIOD_MS } from "../src/motion/scale.generated";

const webviews = path.resolve(import.meta.dir, "..");
const src = path.join(webviews, "src");
const nativeSources = path.resolve(webviews, "../Packages/macOS/CmuxNext/Sources");

function files(dir: string, keep: (file: string) => boolean): string[] {
  return readdirSync(dir, { recursive: true, withFileTypes: true })
    .filter((entry) => entry.isFile())
    .map((entry) => path.join(entry.parentPath, entry.name))
    .filter(keep);
}

const repo = path.resolve(webviews, "..");
const agentChat = path.join(repo, "agent-chat");
const site = path.join(repo, "web/app");
const rel = (file: string) => path.relative(repo, file).split(path.sep).join("/");
const stripComments = (text: string) => text.replace(/\/\*[\s\S]*?\*\//g, "");
const FULL_TURN = /rotate\(\s*-?(?:360deg|1turn)\s*\)/;
/** The arc every spinner draws (conversation/Spinner.tsx `Spinner`'s default look). */
const ARC = "M8 2.75a5.25 5.25 0 1 1-4.55 2.63";

/** CSS rules (comments out, selector flattened) whose block matches `turns` and whose selector `ours` refuses. */
function turningRules(file: string, turns: RegExp, ours: (selector: string) => boolean): string[] {
  const out: string[] = [];
  for (const match of stripComments(readFileSync(file, "utf8")).matchAll(/([^{}]+)\{([^{}]*)\}/g)) {
    const [, selector, block] = match;
    if (!turns.test(block)) continue;
    const clean = selector.trim().replace(/\s+/g, " ");
    if (!ours(clean)) out.push(`${rel(file)} ${clean}`);
  }
  return out;
}

/** Every spinner drawn outside the shared components, across the pages, the agent-chat sidecar and cmux.com. */
export function adHocSpinners(): string[] {
  const found: string[] = [];
  // Pages: only `cv-spinner` turns on the spinner keyframes.
  for (const file of files(src, (name) => name.endsWith(".css")))
    found.push(
      ...turningRules(
        file,
        /animation(-name)?\s*:[^;]*\bcmux-spin\b/,
        (selector) => /(^|[\s,>+~])\.cv-spinner\b/.test(selector) || /\.cv-spinner(\[|:|\s|$)/.test(selector),
      ),
    );
  // Pages: no component writes the keyframes itself.
  const writers = new Set(["ui/spinnerClock.ts", "pages/shared/desktop.ts"]);
  for (const file of files(src, (name) => /\.(ts|tsx)$/.test(name) && !/\.(test|gallery)\.tsx?$/.test(name))) {
    if (writers.has(path.relative(src, file))) continue;
    if (/["'`]cmux-spin\b|animation\s*:\s*["'`][^"'`]*\bcmux-spin\b/.test(readFileSync(file, "utf8")))
      found.push(`${rel(file)} writes cmux-spin`);
  }
  // agent-chat: only `.spinner` (its `Spinner`) turns, and only icons.tsx draws it.
  for (const file of files(path.join(agentChat, "public"), (name) => name.endsWith(".css"))) {
    // Any keyframes that make a full turn, whatever their name.
    const text = stripComments(readFileSync(file, "utf8"));
    const turning = [...text.matchAll(/@keyframes\s+([\w-]+)\s*\{([^{}]*\{[^{}]*\})*[^{}]*\}/g)]
      .filter((match) => FULL_TURN.test(match[0]))
      .map((match) => match[1]);
    if (!turning.length) continue;
    const turns = new RegExp(`animation(-name)?\\s*:[^;]*\\b(${turning.join("|")})\\b`);
    found.push(...turningRules(file, turns, (selector) => /^\.spinner$/.test(selector)));
  }
  for (const file of files(path.join(agentChat, "src"), (name) => /\.tsx?$/.test(name))) {
    if (rel(file) === "agent-chat/src/components/icons.tsx") continue;
    if (/className=["'`{][^>]*\bspinner\b|rotate\(\s*360deg|animate-spin/.test(readFileSync(file, "utf8")))
      found.push(`${rel(file)} draws a spinner`);
  }
  // cmux.com: only app/components/spinner.tsx spins; the hosted handler's restyle of the auth library's own
  // spinner (a third-party element no component can replace) draws the same arc on the same period, no track.
  for (const file of files(site, (name) => /\.(tsx?|css)$/.test(name))) {
    const name = rel(file);
    const text = stripComments(readFileSync(file, "utf8"));
    if (name === "web/app/components/spinner.tsx") continue;
    if (name === "web/app/handler/hosted.module.css") {
      const before = /::before\s*\{([^}]*)\}/.exec(text)?.[1] ?? "";
      if (!before.includes(ARC) || !before.includes(`${SPINNER_PERIOD_MS}ms linear infinite`) || /border/.test(before))
        found.push(`${name} redraws the auth spinner off the shared arc`);
      continue;
    }
    if (/\banimate-spin\b/.test(text) || (/@keyframes/.test(text) && FULL_TURN.test(text)))
      found.push(`${name} spins on its own`);
  }
  return found;
}

test("every spinner is the shared component: zero ad-hoc spinners", () => {
  expect(adHocSpinners()).toEqual([]);
});

test("the shared spinners draw one arc and no track", () => {
  const pages = readFileSync(path.join(src, "agent-session/acpmux/conversation/Spinner.tsx"), "utf8");
  expect(pages).toContain(`"${ARC}"`);
  expect(pages).toMatch(/look = "arc"/);
  for (const file of [path.join(agentChat, "src/components/icons.tsx"), path.join(site, "components/spinner.tsx")]) {
    const text = readFileSync(file, "utf8");
    const body = text.slice(text.indexOf("function Spinner"));
    expect(body).toContain(`d="${ARC}"`);
    expect(body).not.toMatch(/<circle|strokeOpacity/);
  }
  expect(readFileSync(path.join(site, "components/spinner.tsx"), "utf8")).toContain(
    `[animation-duration:${SPINNER_PERIOD_MS}ms]`,
  );
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
