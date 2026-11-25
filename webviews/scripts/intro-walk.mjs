#!/usr/bin/env bun
// The Make cmux Yours intro walk probe (goal intro-walk-front-door, cmuxterm-hq goals/intro-walk-front-door.md).
// It walks every arm of the first-run step in the built gallery (pages.onboarding's make-it-yours variants, on the
// page's own mock host, MockOnboardingProvider) in headless Chromium and checks the walk's three budgets
// (docs/design/make-cmux-yours-intro-walk.md in cmuxterm-hq):
//   - zero layout shift: no named part of the screen moves or resizes when a pick is clicked, read two ways: the
//     browser's own layout-shift entries (CLS, PerformanceObserver) and the parts' boxes before and after;
//   - one publish per pick: each click on a choice sends exactly one op, and Skip sends exactly one;
//   - Skip restores: after picks then Skip, the choices the page shows equal the ones it opened on. The mock answers
//     as the host does (MakeItYoursStepModel: "Skip keeps what is set"), so this reads false until the host's Skip
//     restores the opening settings and the mock follows it.
//
//   bun scripts/intro-walk.mjs [--out report.json] [--reuse-build]
//
// Builds dist/gallery from this checkout first: a dist/gallery left by another branch walks that branch's code
// (a stale build once read Skip as fixed). `--reuse-build` walks an existing dist/gallery as is.
//
// Writes one JSON report: per arm and pick the ops sent, the CLS and the moved parts, and the summary values the
// cmuxterm-hq probe records (`checks`, `passed`, `pass_share`, `shift_max_px`, `cls_max`, `publishes_per_pick_max`,
// `skip_restores`). Exit 0 when every check passed, 1 when a check failed, 2 when the walk could not run.
import fs from "node:fs";
import path from "node:path";
import { spawn } from "node:child_process";
import { chromium } from "playwright";
import { preview } from "vite";

const args = process.argv.slice(2);
const outIndex = args.indexOf("--out");
const out = outIndex >= 0 ? path.resolve(args[outIndex + 1]) : null;
const root = path.resolve(import.meta.dir, "..");

/** The arms walked: each look of the screen, opened fresh (the recommended answers) and on a person's own picks. */
const ARMS = [
  { arm: "cards-fresh", variant: "make-it-yours-cards" },
  { arm: "rows-fresh", variant: "make-it-yours-rows" },
  { arm: "cards-picked", variant: "make-it-yours-picked" },
  { arm: "cards-terminal", variant: "make-it-yours-terminal" },
];
const WIDTHS = ["narrow", "normal", "wide"];
/** The parts that must not move when a pick is clicked. */
const PARTS = {
  work: ".onb-make-work",
  density: ".onb-make-density",
  background: ".onb-make-background",
  footer: ".onb-footer, footer",
  skip: '[data-variant="subtle"]',
  primary: '[data-variant="solid"]',
};
/** Edge moves at or under this many CSS px are subpixel rounding, not a shift. */
const SHIFT_TOLERANCE_PX = 0.5;

async function buildGallery() {
  if (args.includes("--reuse-build") && fs.existsSync(path.join(root, "dist/gallery"))) return;
  const build = spawn("bun", ["run", "gallery:build"], { cwd: root, stdio: "inherit" });
  await new Promise((resolve, reject) => {
    build.once("error", reject);
    build.once("exit", (code) => (code === 0 ? resolve() : reject(new Error(`gallery build exited ${code}`))));
  });
}

/** Runs in the page: each part's box, or null when it is not drawn. */
function readBoxes(parts) {
  const boxes = {};
  for (const [name, selector] of Object.entries(parts)) {
    const element = Array.from(document.querySelectorAll(selector)).find((node) => {
      const rect = node.getBoundingClientRect();
      return rect.width > 0 || rect.height > 0;
    });
    if (!element) {
      boxes[name] = null;
      continue;
    }
    const rect = element.getBoundingClientRect();
    boxes[name] = { x: rect.x, y: rect.y, width: rect.width, height: rect.height };
  }
  return boxes;
}

function moves(before, after) {
  const moved = [];
  for (const [part, from] of Object.entries(before)) {
    const to = after[part];
    if (!from || !to) continue;
    const px = Math.max(
      Math.abs(from.x - to.x),
      Math.abs(from.y - to.y),
      Math.abs(from.x + from.width - (to.x + to.width)),
      Math.abs(from.y + from.height - (to.y + to.height)),
    );
    if (px > SHIFT_TOLERANCE_PX) moved.push({ part, px: Math.round(px * 10) / 10, from, to });
  }
  return moved;
}

const frames = (page) =>
  page.evaluate(() => new Promise((resolve) => requestAnimationFrame(() => requestAnimationFrame(() => resolve()))));

/** Runs in the page: the radios checked, by group. */
function checkedValues() {
  return Object.fromEntries(
    Array.from(document.querySelectorAll('.onb-make input[type="radio"]'))
      .filter((input) => input.checked)
      .map((input) => [input.name, input.value]),
  );
}

async function walkArm(browser, baseUrl, { arm, variant }, width) {
  const context = await browser.newContext({ viewport: { width: 900, height: 640 }, colorScheme: "light" });
  const page = await context.newPage();
  await page.addInitScript(() => {
    globalThis.cmuxOnboardingMockCalls = [];
    globalThis.cmuxLayoutShifts = [];
    new PerformanceObserver((list) => {
      for (const entry of list.getEntries()) globalThis.cmuxLayoutShifts.push(entry.value);
    }).observe({ type: "layout-shift", buffered: true });
  });
  const query = new URLSearchParams({
    entry: "pages.onboarding",
    variant,
    width,
    frame: "component",
    colorScheme: "light",
  });
  await page.goto(`${baseUrl}/frame.html?${query}`, { waitUntil: "domcontentloaded" });
  await page.waitForFunction(() => document.documentElement.dataset.galleryReady === "1", undefined, {
    timeout: 90_000,
  });
  await frames(page);
  const opening = await page.evaluate(checkedValues);
  const radios = await page.evaluate(() =>
    Array.from(document.querySelectorAll('.onb-make input[type="radio"]')).map((input) => ({
      name: input.name,
      value: input.value,
    })),
  );
  // Each choice that is not already checked, in the order a person reads them; then back to where it opened.
  const picks = radios.filter((radio) => opening[radio.name] !== radio.value);
  const steps = [];
  const click = async (label, locator) => {
    const before = await page.evaluate(readBoxes, PARTS);
    await page.evaluate(() => {
      globalThis.cmuxOnboardingMockCalls.length = 0;
      globalThis.cmuxLayoutShifts.length = 0;
    });
    await locator.click();
    await frames(page);
    await frames(page);
    const after = await page.evaluate(readBoxes, PARTS);
    const { calls, cls } = await page.evaluate(() => ({
      calls: globalThis.cmuxOnboardingMockCalls.map((call) => call.op),
      cls: globalThis.cmuxLayoutShifts.reduce((sum, value) => sum + value, 0),
    }));
    const step = { step: label, ops: calls, cls: Math.round(cls * 10000) / 10000, moved: moves(before, after) };
    steps.push(step);
    return step;
  };
  for (const { name, value } of picks) {
    const step = await click(
      `${name}=${value || "none"}`,
      page.locator(`.onb-make input[name="${name}"][value="${value}"]`).locator(".."),
    );
    // The pick must show: a click the page sent but never drew would make every other check here vacuous.
    step.shown = (await page.evaluate(checkedValues))[name] === value;
  }
  await click("skip", page.locator('[data-variant="subtle"]').first());
  const afterSkip = await page.evaluate(checkedValues);
  await context.close();
  return {
    arm,
    width,
    variant,
    opening,
    afterSkip,
    skipRestores: JSON.stringify(afterSkip) === JSON.stringify(opening),
    steps,
  };
}

async function main() {
  await buildGallery();
  const server = await preview({
    root,
    configFile: path.join(root, "vite.config.gallery.ts"),
    preview: { host: "127.0.0.1", port: 0 },
  });
  const address = server.httpServer.address();
  if (!address || typeof address === "string") throw new Error("gallery preview did not bind a TCP port");
  const baseUrl = `http://127.0.0.1:${address.port}`;
  const browser = await chromium.launch();
  const walks = [];
  const started = Date.now();
  try {
    for (const arm of ARMS) for (const width of WIDTHS) walks.push(await walkArm(browser, baseUrl, arm, width));
  } finally {
    await browser.close();
    await server.close();
  }
  let checks = 0;
  let passed = 0;
  const failures = [];
  const judge = (ok, what) => {
    checks += 1;
    if (ok) passed += 1;
    else failures.push(what);
  };
  let shiftMax = 0;
  let clsMax = 0;
  let publishesMax = 0;
  for (const walk of walks) {
    for (const step of walk.steps) {
      const px = Math.max(0, ...step.moved.map((move) => move.px));
      shiftMax = Math.max(shiftMax, px);
      clsMax = Math.max(clsMax, step.cls);
      publishesMax = Math.max(publishesMax, step.ops.length);
      judge(
        step.moved.length === 0 && step.cls === 0,
        `${walk.arm}/${walk.width} ${step.step}: layout shift ${px} px, CLS ${step.cls}`,
      );
      if (step.step !== "skip") judge(step.shown, `${walk.arm}/${walk.width} ${step.step}: the pick did not show`);
      judge(
        step.ops.length === 1,
        `${walk.arm}/${walk.width} ${step.step}: ${step.ops.length} ops (${step.ops.join(", ")})`,
      );
    }
    judge(
      walk.skipRestores,
      `${walk.arm}/${walk.width}: Skip left ${JSON.stringify(walk.afterSkip)}, opened on ${JSON.stringify(walk.opening)}`,
    );
  }
  const report = {
    probe: "intro-walk-gallery",
    ms: Date.now() - started,
    checks,
    passed,
    pass_share: checks ? Math.round((passed / checks) * 10000) / 10000 : 0,
    shift_max_px: shiftMax,
    cls_max: clsMax,
    publishes_per_pick_max: publishesMax,
    skip_restores: walks.length > 0 && walks.every((walk) => walk.skipRestores),
    failures,
    walks,
  };
  const text = `${JSON.stringify(report, null, 2)}\n`;
  if (out) fs.writeFileSync(out, text);
  console.log(JSON.stringify({ ...report, walks: undefined, failures: failures.slice(0, 20) }, null, 2));
  process.exit(failures.length ? 1 : 0);
}

main().catch((error) => {
  console.error(error);
  process.exit(2);
});
