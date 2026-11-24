// l10n-allow-file: benchmark output, not shipped UI.
// The sidebar chats page flung fast at N Earlier rows on Chromium, a production build of
// test/browser/sidebar-chats-visible-only.html (the real page over the stand-in host of
// bench/sidebar-chats-visible-only.bench.ts). Where that bench scrolls 30 px a frame, this one scrolls as a
// fast trackpad fling does (300 and 1500 px a frame) and jumps as a click on the scroller's track does
// (scrollTop to a random far offset), and reads every painted frame. Three hosts:
//   all     no slice ever reaches the page (every row mounted): the app at feat-cmux-next 762b0f408b8, whose
//           SidebarChatHistoryProvider serves the block stream only, so the page's slice subscribe is refused;
//   slice   the stand-in host as it is: its slice is measured in the same frame as the scroll once a scroll is
//           under way (its frame callback runs after the bench's), one frame late after a jump;
//   late    the stand-in's slice delivered one frame after it was measured, as a native host that answers the
//           list's scroll after the frame would.
// Per N, host and motion:
//   work    main-thread ms per frame p50/p95 (from the frame's callbacks, where the bench moves the page, to
//           the task after it painted), and the frames over 16.7 ms;
//   blank   painted frames whose viewport shows a part of the rows no mounted row covers (a spacer's empty
//           place), and for the jumps the time and frames from the jump to the first painted frame with no gap.
//   bun bench/sidebar-chats-fling.bench.ts [n...]   (default 200 500 1000 10000)
/// <reference types="bun" />
import type { Page } from "playwright";
import { chromium } from "./browsers";
import { benchPositionals, gotoBenchPage, requireProductionReact, serveBenchPage } from "./support/benchPage";
import { perfRow, TARGET_MS } from "./perfRow";
import { installPaintedFrames } from "../test/support/paintedFrames";

declare global {
  interface Window {
    benchReady: boolean;
  }
}

type Host = "all" | "slice" | "late";
const HOSTS: Host[] = ["all", "slice", "late"];
const SIZES = benchPositionals().map(Number);
const NS = SIZES.length ? SIZES : [200, 500, 1_000, 10_000];
const FLINGS = [300, 1_500];
const FRAMES = 120;
const JUMPS = 30;
const FRAME_MS = 1000 / 60;

const pct = (values: number[], p: number) =>
  values.length ? [...values].sort((a, b) => a - b)[Math.max(0, Math.ceil(values.length * p) - 1)]! : 0;

/// Installed before the harness runs. The harness hands its slice to the page through
/// `listeners.get("cmux.sidebarChats.slice")` (a Map); this bench cannot change the harness, so it answers that
/// one key of every Map: with nothing (`all`), or with a function that hands the slice on a frame later (`late`).
function hostScript(host: Host) {
  if (host === "slice") return;
  const key = "cmux.sidebarChats.slice";
  const get = Map.prototype.get;
  Map.prototype.get = function (this: Map<unknown, unknown>, name: unknown) {
    const found = get.call(this, name);
    if (name !== key || typeof found !== "function") return found;
    if (host === "all") return undefined;
    return (data: unknown) => requestAnimationFrame(() => (found as (data: unknown) => void)(data));
  };
}

/// In the page: whether the painted viewport shows a part of the rows that no mounted row covers.
function definePageProbe() {
  const w = window as unknown as { benchGap(): number };
  w.benchGap = () => {
    const block = document.querySelector<HTMLElement>(".sc-block");
    if (!block) return 0;
    const header = block.querySelector<HTMLElement>(".sc-header")!.getBoundingClientRect();
    const tail = block.querySelector<HTMLElement>(".sc-tail");
    const rowsTop = header.bottom;
    const rowsBottom = tail ? tail.getBoundingClientRect().top : block.getBoundingClientRect().bottom;
    const top = Math.max(0, rowsTop);
    const bottom = Math.min(innerHeight, rowsBottom);
    if (bottom <= top) return 0;
    const rows = block.querySelectorAll<HTMLElement>(".sc-row[data-chat]");
    if (!rows.length) return bottom - top;
    // A row's spacing under it is part of its place (2 px): allow it.
    const first = rows[0]!.getBoundingClientRect().top;
    const last = rows[rows.length - 1]!.getBoundingClientRect().bottom + 2;
    const covered = Math.max(0, Math.min(bottom, last) - Math.max(top, first));
    return Math.max(0, bottom - top - covered);
  };
}

interface FlingResult {
  work: number[];
  blank: number;
}

/// Scrolls `step` px a frame for FRAMES frames (back up from the end when it runs out), reading each painted frame.
function fling(page: Page, step: number, probe: boolean) {
  return page.evaluate(
    ({ step, frames, probe }) =>
      new Promise<FlingResult>((resolve) => {
        const scroller = document.scrollingElement!;
        const gap = (window as unknown as { benchGap(): number }).benchGap;
        const work: number[] = [];
        let blank = 0;
        let started = 0;
        let frame = 0;
        let direction = 1;
        window.cmuxAfterPaint(
          () => {
            if (frame > 1) {
              work.push(performance.now() - started);
              if (probe && gap() > 0) blank++;
            }
            if (frame <= frames) return true;
            resolve({ work, blank });
            return false;
          },
          () => {
            frame++;
            started = performance.now();
            const max = scroller.scrollHeight - innerHeight;
            if (scroller.scrollTop + step * direction > max || scroller.scrollTop + step * direction < 0)
              direction = -direction;
            scroller.scrollTop += step * direction;
          },
        );
      }),
    { step, frames: FRAMES, probe },
  );
}

interface JumpResult {
  /// ms from the jump frame's callbacks to the first painted frame with no gap.
  fill: number;
  /// Painted frames with a gap before it (0: the jump frame itself was filled).
  blankFrames: number;
  /// Main-thread ms of the jump frame.
  work: number;
}

/// Jumps scrollTop to `to` in one frame and reads painted frames until none shows a gap (at most 30).
function jump(page: Page, to: number, probe: boolean) {
  return page.evaluate(
    ({ to, probe }) =>
      new Promise<JumpResult>((resolve) => {
        const gap = (window as unknown as { benchGap(): number }).benchGap;
        let started = 0;
        let frame = 0;
        let work = 0;
        window.cmuxAfterPaint(
          () => {
            if (frame === 1) work = performance.now() - started;
            const filled = !probe || gap() === 0;
            if (filled || frame > 30) {
              resolve({ fill: performance.now() - started, blankFrames: frame - 1, work });
              return false;
            }
            return true;
          },
          () => {
            frame++;
            if (frame === 1) {
              started = performance.now();
              document.scrollingElement!.scrollTop = to;
            }
          },
        );
      }),
    { to, probe },
  );
}

const browser = await chromium.launch({ headless: true });
const served = await serveBenchPage("/test/browser/sidebar-chats-visible-only.html");
const paint = (page: Page) => page.evaluate(() => window.cmuxPaintFrame());
const fmt = (value: number) => value.toFixed(1);
try {
  console.log(`sidebar-chats-fling build=${served.dev ? "dev" : "production"} frames=${FRAMES} jumps=${JUMPS}`);
  for (const n of NS) {
    for (const host of HOSTS) {
      const context = await browser.newContext({ viewport: { width: 260, height: 800 } });
      const page = await context.newPage();
      await page.addInitScript(hostScript, host);
      await installPaintedFrames(page);
      const loadStart = Date.now();
      await gotoBenchPage(page, { ...served, url: `${served.url}#n=${n}` });
      await requireProductionReact(page, { dev: served.dev });
      await page.waitForFunction(() => window.benchReady === true);
      const loadMs = Date.now() - loadStart;
      await page.evaluate(definePageProbe);
      for (let frame = 0; frame < 3; frame++) await paint(page);
      const mounted = await page.evaluate(() => ({
        rows: document.querySelectorAll(".sc-row[data-chat]").length,
        nodes: document.getElementById("root")!.querySelectorAll("*").length,
        max: document.scrollingElement!.scrollHeight - innerHeight,
      }));
      // All rows mounted: no gap is possible in the DOM (a raster checkerboard is not visible to script).
      const probe = host !== "all";
      const parts: string[] = [];
      for (const step of FLINGS) {
        await page.evaluate(() => (document.scrollingElement!.scrollTop = 0));
        for (let frame = 0; frame < 3; frame++) await paint(page);
        const { work, blank } = await fling(page, step, probe);
        const over = work.filter((ms) => ms > FRAME_MS).length;
        parts.push(
          `fling${step}: work p50/p95 ${fmt(pct(work, 0.5))}/${fmt(pct(work, 0.95))}ms over16.7=${over}/${work.length} blank=${blank}/${work.length}`,
        );
        perfRow({
          name: `sidebar_chats_fling.n${n}.${host}.fling${step}.work`,
          p50: pct(work, 0.5),
          p95: pct(work, 0.95),
          target: TARGET_MS.frameWork,
        });
        if (probe)
          perfRow({
            name: `sidebar_chats_fling.n${n}.${host}.fling${step}.blank`,
            p95: blank,
            unit: "frames",
            target: 0,
          });
      }
      // A seeded walk of far offsets, so every run and host jumps to the same places.
      let seed = 0x5eed + n;
      const random = () => (seed = (seed * 1_103_515_245 + 12_345) & 0x7fffffff) / 0x7fffffff;
      const fills: number[] = [];
      const blanks: number[] = [];
      const jumpWork: number[] = [];
      for (let index = 0; index < JUMPS; index++) {
        const to = Math.round(random() * mounted.max);
        const result = await jump(page, to, probe);
        fills.push(result.fill);
        blanks.push(result.blankFrames);
        jumpWork.push(result.work);
        for (let frame = 0; frame < 2; frame++) await paint(page);
      }
      const blankJumps = blanks.filter((frames) => frames > 0).length;
      parts.push(
        `jump: fill p50/p95 ${fmt(pct(fills, 0.5))}/${fmt(pct(fills, 0.95))}ms blankFrames p50/max ${pct(blanks, 0.5)}/${Math.max(...blanks)} ` +
          `blankJumps=${blankJumps}/${JUMPS} jumpFrameWork p95 ${fmt(pct(jumpWork, 0.95))}ms`,
      );
      perfRow({
        name: `sidebar_chats_fling.n${n}.${host}.jump.fill`,
        p50: pct(fills, 0.5),
        p95: pct(fills, 0.95),
        target: TARGET_MS.response,
      });
      await context.close();
      console.log(
        `n=${n} host=${host} load=${loadMs}ms rows=${mounted.rows} nodes=${mounted.nodes}\n  ${parts.join("\n  ")}`,
      );
    }
  }
} finally {
  await browser.close();
  await served.close();
}
