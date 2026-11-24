// l10n-allow-file: recorder overlay text, not shipped UI.
// Records a video and stills of the open chat's composer while things above it change (the steps of
// agent-pane-composer-anchored-above.test.ts), with a fixed reference line at the composer card's
// starting top and bottom. RECORD_LABEL names the run (before/after); files go to $FAST_CHECKS_OUT/LABEL.
import { mkdir, writeFile } from "node:fs/promises";
import path from "node:path";
import { afterAll, beforeAll, expect, setDefaultTimeout, test } from "bun:test";
import { chromium, type Browser, type Page } from "playwright";
import { installPaintedFrames } from "./support/paintedFrames";
import { papercutPane } from "./support/papercutChat";

setDefaultTimeout(300_000);
const LABEL = process.env.RECORD_LABEL ?? "after";
const OUT = path.join(process.env.FAST_CHECKS_OUT ?? "/tmp/composer-record", LABEL);
const TURNS = 30;
const VIEWPORT = { width: 900, height: 380 };
let browser: Browser;
let pane: Awaited<ReturnType<typeof papercutPane>>;

beforeAll(async () => {
  await mkdir(OUT, { recursive: true });
  browser = await chromium.launch({ headless: true });
  pane = await papercutPane(() => browser, { turns: TURNS, running: false });
});
afterAll(async () => {
  await pane?.close();
  await browser?.close();
});

type Box = { top: number; bottom: number; height: number };
type Step = { name: string; still?: string; run: (page: Page) => Promise<unknown> };
const inPage =
  <T>(fn: (arg: T) => unknown, arg: T) =>
  (page: Page) =>
    page.evaluate(fn as never, arg as never);

const headerTo = (delta: number | null) =>
  inPage((delta) => {
    const header = document.querySelector<HTMLElement>(".acpmux-header")!;
    if (delta === null) {
      header.style.removeProperty("flex-basis");
      header.style.removeProperty("height");
      delete header.dataset.testBase;
      return;
    }
    header.dataset.testBase ??= String(header.getBoundingClientRect().height);
    const height = `${Number(header.dataset.testBase) + delta}px`;
    header.style.flexBasis = height;
    header.style.height = height;
  }, delta);
const banner = (on: boolean) =>
  inPage((on) => {
    document.querySelector("[data-test-banner]")?.remove();
    if (!on) return;
    const stage = document.querySelector<HTMLElement>(".acpmux-main > .acpmux-stage")!;
    const node = document.createElement("div");
    node.className = "ui-notice";
    node.dataset.testBanner = "";
    node.style.cssText = "flex:none;height:48px;padding:12px;box-sizing:border-box";
    node.textContent = "Stand-in banner at the top of the stage";
    stage.insertBefore(node, stage.firstChild);
  }, on);
const connecting = (on: boolean) =>
  inPage((on) => {
    document.querySelector("[data-test-unavailable]")?.remove();
    const stage = document.querySelector<HTMLElement>(".acpmux-main > .acpmux-stage")!;
    const hidden = [...stage.children].filter(
      (child) => child !== stage.querySelector(".acpmux-header") && !(child as HTMLElement).dataset.testBanner,
    ) as HTMLElement[];
    for (const child of hidden) child.style.display = on ? "none" : "";
    if (!on) return;
    const node = document.createElement("div");
    node.className = "acpmux-empty acpmux-unavailable";
    node.dataset.unavailable = "connecting";
    node.dataset.testUnavailable = "";
    stage.appendChild(node);
  }, on);
const inspector = (open: boolean) =>
  inPage(
    (open) =>
      (window as unknown as { cmuxAcpmuxBridge: { toggleInspector(open: boolean): void } }).cmuxAcpmuxBridge.toggleInspector(
        open,
      ),
    open,
  );

const STEPS: Step[] = [
  { name: "inspector open", still: "inspector-open", run: inspector(true) },
  { name: "inspector closed", run: inspector(false) },
  { name: "header +28 px", run: headerTo(28) },
  { name: "header +60 px", still: "header-60", run: headerTo(60) },
  { name: "header +0 px", run: headerTo(0) },
  { name: "header reset", run: headerTo(null) },
  { name: "banner on", still: "banner-on", run: banner(true) },
  { name: "banner off", run: banner(false) },
  { name: "connecting on", still: "connecting-on", run: connecting(true) },
  { name: "connecting off", run: connecting(false) },
];

test(`record ${LABEL}: things above the composer change at ${VIEWPORT.width}x${VIEWPORT.height}`, async () => {
  const page = await browser.newPage({ viewport: VIEWPORT, recordVideo: { dir: OUT, size: VIEWPORT } });
  await installPaintedFrames(page);
  await page.goto(pane.address());
  await page.getByText(`Answer ${TURNS}:`, { exact: false }).waitFor({ timeout: 120_000 });
  await page.waitForTimeout(800);
  // A tall draft (14 lines): the card a short pane clamps.
  await page.locator(".acpmux-composer-box [contenteditable]").first().click();
  await page.keyboard.type("draft");
  for (let n = 1; n < 14; n++) {
    await page.keyboard.press("Shift+Enter");
    await page.keyboard.type(`line ${n}`);
  }
  await page.waitForTimeout(800);
  // The reference lines at the card's starting top and bottom, a caption, and a per-frame recorder.
  await page.evaluate((label) => {
    const read = (selector: string) => {
      const rect = document.querySelector(selector)?.getBoundingClientRect();
      if (!rect || rect.height <= 0) return undefined;
      const round = (value: number) => Math.round(value * 10) / 10;
      return { top: round(rect.top), bottom: round(rect.bottom), height: round(rect.height) };
    };
    const start = { composer: read("form.acpmux-composer")!, box: read(".acpmux-composer-box")! };
    const layer = document.createElement("div");
    layer.style.cssText = "position:fixed;inset:0;pointer-events:none;z-index:2147483647";
    const line = (y: number, color: string) => {
      const node = document.createElement("div");
      node.style.cssText = `position:absolute;left:0;right:0;top:${y - 1}px;height:2px;background:${color}`;
      layer.appendChild(node);
    };
    line(start.box.top, "#ff2d55");
    line(start.box.bottom, "#ff9500");
    const caption = document.createElement("div");
    caption.style.cssText =
      "position:absolute;right:8px;top:8px;padding:4px 8px;border-radius:6px;background:rgba(0,0,0,.82);color:#fff;font:600 13px/1.35 ui-monospace,Menlo,monospace;white-space:pre";
    layer.appendChild(caption);
    document.body.appendChild(layer);
    const globals = window as unknown as Record<string, unknown>;
    const state = { step: "start", frames: [] as { step: string; composer?: Box; box?: Box }[] };
    type Box = { top: number; bottom: number; height: number };
    globals.__rec = state;
    globals.__recStart = start;
    window.cmuxAfterPaint(() => {
      const frame = { step: state.step, composer: read("form.acpmux-composer"), box: read(".acpmux-composer-box") };
      state.frames.push(frame);
      const dy = frame.box ? Math.round((frame.box.top - start.box.top) * 10) / 10 : NaN;
      const dh = frame.box ? Math.round((frame.box.height - start.box.height) * 10) / 10 : NaN;
      caption.textContent = `${label.toUpperCase()}  ${state.step}\ncard top ${dy >= 0 ? "+" : ""}${dy} px  height ${dh >= 0 ? "+" : ""}${dh} px`;
    });
  }, LABEL);
  await page.waitForTimeout(1200);
  await page.screenshot({ path: path.join(OUT, "00-start.png") });
  let index = 1;
  for (const step of STEPS) {
    await page.evaluate((name) => ((window as unknown as { __rec: { step: string } }).__rec.step = name), step.name);
    await step.run(page);
    await page.waitForTimeout(1300);
    if (step.still) await page.screenshot({ path: path.join(OUT, `${String(index++).padStart(2, "0")}-${step.still}.png`) });
  }
  await page.waitForTimeout(600);
  const { frames, start } = await page.evaluate(() => {
    const globals = window as unknown as { __rec: { frames: unknown[] }; __recStart: unknown };
    return { frames: globals.__rec.frames, start: globals.__recStart };
  });
  type Frame = { step: string; composer?: Box; box?: Box };
  const first = start as { composer: Box; box: Box };
  const perStep = ["start", ...STEPS.map((step) => step.name)].map((name) => {
    const drawn = (frames as Frame[]).filter((frame) => frame.step === name && frame.composer && frame.box);
    const max = (part: "composer" | "box", edge: keyof Box) =>
      Math.round(Math.max(0, ...drawn.map((frame) => Math.abs(frame[part]![edge] - first[part][edge]))) * 10) / 10;
    return {
      step: name,
      frames: drawn.length,
      composer: { top: max("composer", "top"), bottom: max("composer", "bottom"), height: max("composer", "height") },
      box: { top: max("box", "top"), bottom: max("box", "bottom"), height: max("box", "height") },
    };
  });
  const result = { label: LABEL, viewport: `${VIEWPORT.width}x${VIEWPORT.height}`, start: first, steps: perStep };
  console.log(`composer-record: ${JSON.stringify(result)}`);
  await writeFile(path.join(OUT, "steps.json"), JSON.stringify(result, null, 2));
  const video = page.video();
  await page.context().close();
  await video?.saveAs(path.join(OUT, `composer-${LABEL}-900x380.webm`));
  await video?.delete();
  expect(perStep.every((step) => step.frames > 0)).toBe(true);
});
