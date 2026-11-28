// Review by doing (cmuxterm-hq#23817): replay a recording (recording.ts) in a Playwright page on a
// gallery stage and say whether the reviewer's expectations hold. The CLI (replay.ts) serves a
// head's built gallery; a generated regression test (replay.ts to-test) serves the dev gallery. Both
// call `replayOnPage`, so a recording and its test cannot disagree about what a step means.

import type { Locator, Page } from "playwright";
import type { Edge, Expectation, Recording, Step, Target } from "./recording";

/** Where a press lands in `box`: its center, or 3 px inside an edge or corner. */
export function pressPoint(box: { x: number; y: number; width: number; height: number }, from?: Edge) {
  const inset = 3;
  const edge = from ?? "";
  const x = edge.includes("left")
    ? box.x + inset
    : edge.includes("right")
      ? box.x + box.width - inset
      : box.x + box.width / 2;
  const y = edge.includes("top")
    ? box.y + inset
    : edge.includes("bottom")
      ? box.y + box.height - inset
      : box.y + box.height / 2;
  return { x, y };
}

/** The frame.html query for a recording's surface (galleryFrame or a static build prefixes it). */
export function surfaceParams(recording: Recording): Record<string, string> {
  const { entry, variant, opts, width, height, colorScheme } = recording.surface;
  const params: Record<string, string> = { entry, frame: "component", colorScheme: colorScheme ?? "light" };
  if (variant) params.variant = variant;
  if (opts) params.opts = opts;
  params.width = width ? String(width) : "normal";
  if (height) params.height = String(height);
  return params;
}

export function describeTarget(target: Target): string {
  if ("role" in target) return target.name === undefined ? target.role : `${target.role} "${target.name}"`;
  if ("testId" in target) return `test id ${target.testId}`;
  if ("text" in target) return `text "${target.text}"`;
  return target.selector;
}

function locate(page: Page, target: Target): Locator {
  let found: Locator;
  if ("role" in target)
    found = page.getByRole(target.role as Parameters<Page["getByRole"]>[0], {
      ...(target.name === undefined ? {} : { name: target.name }),
      exact: target.exact ?? false,
    });
  else if ("testId" in target) found = page.getByTestId(target.testId);
  else if ("text" in target) found = page.getByText(target.text);
  else found = page.locator(target.selector);
  return found.filter({ visible: true });
}

/**
 * What a reviewer waits for before judging the screen: running animations end (a menu's close, at
 * most a second), then two frames and a short pause.
 */
async function settle(page: Page): Promise<void> {
  await page.evaluate(async () => {
    const running = document.getAnimations().map((animation) => animation.finished.catch(() => undefined));
    await Promise.race([Promise.all(running), new Promise((resolve) => setTimeout(resolve, 1_000))]);
    await new Promise((resolve) => requestAnimationFrame(() => requestAnimationFrame(() => setTimeout(resolve, 150))));
  });
}

async function runStep(page: Page, step: Step, timeout: number): Promise<void> {
  if ("click" in step) return locate(page, step.click).first().click({ timeout });
  if ("hover" in step) return locate(page, step.hover).first().hover({ timeout });
  if ("type" in step) {
    if (step.into) return locate(page, step.into).first().fill(step.type, { timeout });
    return page.keyboard.type(step.type);
  }
  if ("press" in step) return page.keyboard.press(step.press);
  const handle = locate(page, step.drag).first();
  await handle.waitFor({ state: "visible", timeout });
  const box = await handle.boundingBox();
  if (!box) throw new Error(`drag: ${describeTarget(step.drag)} has no box`);
  const { x, y } = pressPoint(box, step.from);
  await page.mouse.move(x, y);
  await page.mouse.down();
  await page.mouse.move(x + step.dx, y + step.dy, { steps: 8 });
  await page.mouse.up();
}

/** What the page shows for one expectation, or undefined when it holds. */
async function judge(page: Page, expectation: Expectation): Promise<string | undefined> {
  const what = describeTarget(expectation.target);
  const found = locate(page, expectation.target);
  const count = await found.count();
  if ((expectation.state ?? "visible") === "absent")
    return count === 0 ? undefined : `${what}: expected absent, ${count} visible`;
  if (count === 0) return `${what}: expected visible, none`;
  const element = found.first();
  if (expectation.text !== undefined) {
    const text = (await element.textContent()) ?? "";
    if (!text.includes(expectation.text))
      return `${what}: expected text "${expectation.text}", got "${text.slice(0, 80)}"`;
  }
  for (const [name, value] of Object.entries(expectation.attr ?? {})) {
    const actual = await element.getAttribute(name);
    if (actual !== value) return `${what}: expected ${name}="${value}", got ${JSON.stringify(actual)}`;
  }
  if (expectation.box) {
    const box = await element.boundingBox();
    if (!box) return `${what}: no box`;
    const { minWidth, maxWidth, minHeight, maxHeight } = expectation.box;
    const width = Math.round(box.width);
    const height = Math.round(box.height);
    if (minWidth !== undefined && width < minWidth) return `${what}: width ${width} < ${minWidth}`;
    if (maxWidth !== undefined && width > maxWidth) return `${what}: width ${width} > ${maxWidth}`;
    if (minHeight !== undefined && height < minHeight) return `${what}: height ${height} < ${minHeight}`;
    if (maxHeight !== undefined && height > maxHeight) return `${what}: height ${height} > ${maxHeight}`;
  }
  return undefined;
}

export type ReplayResult = {
  pass: boolean;
  /** The first step that could not run, or every expectation that did not hold. */
  failures: string[];
  /** From navigation to the verdict. */
  ms: number;
};

/**
 * Opens `url` (a frame.html for the recording's surface) in `page`, runs the steps and judges the
 * expectations. They get `expectMs` to come true (a late layout), and a pass must still hold
 * `holdMs` later: a menu caught mid-close is not a menu that stayed open.
 */
export async function replayOnPage(
  page: Page,
  url: string,
  recording: Recording,
  { stepMs = 5_000, expectMs = 1_500, holdMs = 400 }: { stepMs?: number; expectMs?: number; holdMs?: number } = {},
): Promise<ReplayResult> {
  const started = Date.now();
  await page.goto(url, { waitUntil: "domcontentloaded" });
  await page.waitForFunction(() => document.documentElement.dataset.galleryReady, undefined, { timeout: 60_000 });
  const ready = await page.evaluate(() => document.documentElement.dataset.galleryReady);
  if (ready !== "1") return { pass: false, failures: [`stage did not mount (${ready})`], ms: Date.now() - started };
  await settle(page);
  for (const [index, step] of recording.steps.entries()) {
    try {
      await runStep(page, step, stepMs);
    } catch (error) {
      const reason = String(error).split("\n")[0];
      return { pass: false, failures: [`steps[${index}]: ${reason}`], ms: Date.now() - started };
    }
    await settle(page);
  }
  const judgeAll = async () => {
    const found: string[] = [];
    for (const expectation of recording.expect) {
      const failure = await judge(page, expectation);
      if (failure) found.push(failure);
    }
    return found;
  };
  const deadline = Date.now() + expectMs;
  let failures = await judgeAll();
  while (failures.length > 0 && Date.now() < deadline) {
    await page.waitForTimeout(100);
    failures = await judgeAll();
  }
  if (failures.length === 0) {
    await page.waitForTimeout(holdMs);
    await settle(page);
    failures = (await judgeAll()).map((failure) => `did not hold: ${failure}`);
  }
  return { pass: failures.length === 0, failures, ms: Date.now() - started };
}
