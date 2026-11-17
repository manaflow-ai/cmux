// l10n-allow-file: the gallery fixture supplies the transcript's messages.
// No hole between activity rows, whatever is open, through every fold, scroll and width change
// (Leo, 2026-11-17: "why is there this big gap when i have shit expanded", on an opened "Worked for"
// whose rows 'Write round 4 script', 'Received 3 messages', 'Used a tool and ran 2 commands' stood
// ~60px apart, some open, some closed; "THE F---ING SHIFTS EVERY TIME IM SCROLLING").
//
// The chat is his shape (conversation/TranscriptRowHoles.gallery.ts), drawn by the real pane. Once
// following the bottom (the last turn) and once scrolled up mid-history (a middle turn under the view's
// top), the reader opens the turn's "Worked for", then: expands one row, expands several, collapses
// one while the others stay open, collapses them all, expands several again, scrolls four views away
// (the rows unmount) and back, narrows the pane and widens it again, closes "Worked for" with rows
// open and opens it again. Every painted frame of every step is read (support/rowHoles.ts):
// - HOLE: after each step settles, every pair of adjacent rows in view sits exactly its designed
//   gap apart (the gap the layout placed, `.acpmux-row__gap`), within 1px: no hole, no overlap.
// - BLANK: no frame shows an uncovered band taller than 40px between the first and last row in view.
// - SHIFT: scrolled up, a toggle moves neither its own line nor the "Worked for" line above it.
// - LEFTOVER: once settled, no row wears a translate, no fold an inline height, no fold clip remains.
import { afterAll, beforeAll, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser, type Page } from "playwright";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";
import { installPaintedFrames } from "./support/paintedFrames";
import { requireBrowserLane } from "./support/requireBrowserLane";

// This pins the static hole only. The general layout-stability gate (rows entering, leaving or
// moving with no input to explain it) is the layoutWatch.ts watcher, not this file.
//
// The transcript places each row at the sum of the placed heights above it plus the designed gap
// between each pair (transcriptGrid.ts `transcriptGap`, through the geometry's `gapAt`), and draws
// that gap under each row as its `.acpmux-row__gap` span. So between adjacent mounted rows a and b,
// on screen (getBoundingClientRect, so a riding translate counts): b.top - a.bottom === a's gap.
type RowHole = { above: string; below: string; hole: number; inView: boolean };
type RowFrame = { holes: RowHole[]; blank: number; leftovers: string[]; tops: Record<string, number> };
type RowSample = {
  frames: number;
  worstHole?: RowHole & { frame: number };
  worstBlank: number;
  moved: Record<string, number>;
};

declare global {
  interface Window {
    cmuxRowHoles: {
      read(track?: Record<string, string>): RowFrame;
      start(track?: Record<string, string>): void;
      stop(): RowSample;
    };
  }
}

/** The page side; runs in the page, so it closes over nothing. */
function defineRowHoles() {
  if (window.cmuxRowHoles) return;
  const SLACK = 1;
  const read = (track: Record<string, string> = {}) => {
    const scroller = document.querySelector<HTMLElement>(".acpmux-scroll");
    const out = { holes: [] as RowHole[], blank: 0, leftovers: [] as string[], tops: {} as Record<string, number> };
    if (!scroller) return out;
    const view = scroller.getBoundingClientRect();
    const rows: { id: string; pos: number; top: number; bottom: number; gap: number }[] = [];
    for (const node of scroller.querySelectorAll<HTMLElement>("article.acpmux-row")) {
      const box = node.getBoundingClientRect();
      const span = node.querySelector<HTMLElement>(":scope > .acpmux-row__gap");
      rows.push({
        id: node.dataset.rowId ?? "?",
        pos: Number(node.getAttribute("aria-posinset")),
        top: box.top,
        bottom: box.bottom,
        gap: parseFloat(span?.style.height ?? "") || 0,
      });
      if (node.style.translate !== "" && node.style.translate !== "none")
        out.leftovers.push(`row ${node.dataset.rowId} translate ${node.style.translate}`);
    }
    rows.sort((a, b) => a.pos - b.pos);
    for (let index = 1; index < rows.length; index += 1) {
      const above = rows[index - 1]!;
      const below = rows[index]!;
      if (below.pos !== above.pos + 1) continue;
      const hole = below.top - above.bottom - above.gap;
      if (Math.abs(hole) <= SLACK) continue;
      const inView = above.bottom < view.bottom && below.top > view.top;
      out.holes.push({ above: above.id, below: below.id, hole: Math.round(hole * 10) / 10, inView });
    }
    const spans = rows
      .map((row) => [Math.max(view.top, row.top), Math.min(view.bottom, row.bottom + row.gap)] as const)
      .filter(([top, bottom]) => bottom > top)
      .sort((a, b) => a[0] - b[0]);
    let reach = spans[0]?.[1];
    for (const [top, bottom] of spans.slice(1)) {
      if (reach !== undefined && top - reach > out.blank) out.blank = Math.round((top - reach) * 10) / 10;
      reach = Math.max(reach ?? bottom, bottom);
    }
    for (const fold of scroller.querySelectorAll<HTMLElement>(".cv-fold"))
      if (fold.style.height !== "") out.leftovers.push(`.cv-fold height ${fold.style.height}`);
    for (const clip of scroller.querySelectorAll<HTMLElement>("[data-fold-clip]"))
      out.leftovers.push(`[data-fold-clip] on ${clip.className}`);
    for (const [name, selector] of Object.entries(track)) {
      const node = document.querySelector<HTMLElement>(selector);
      if (node) out.tops[name] = node.getBoundingClientRect().top;
    }
    return out;
  };
  let stopSampling: (() => void) | undefined;
  let sample: RowSample = { frames: 0, worstBlank: 0, moved: {} };
  window.cmuxRowHoles = {
    read,
    start(track = {}) {
      stopSampling?.();
      sample = { frames: 0, worstBlank: 0, moved: {} };
      const first = read(track).tops;
      stopSampling = window.cmuxAfterPaint(() => {
        const frame = read(track);
        sample.frames += 1;
        for (const hole of frame.holes)
          if (hole.inView && (!sample.worstHole || Math.abs(hole.hole) > Math.abs(sample.worstHole.hole)))
            sample.worstHole = { ...hole, frame: sample.frames };
        sample.worstBlank = Math.max(sample.worstBlank, frame.blank);
        for (const [name, top] of Object.entries(frame.tops))
          if (first[name] !== undefined)
            sample.moved[name] = Math.max(sample.moved[name] ?? 0, Math.round(Math.abs(top - first[name]!) * 10) / 10);
      });
    },
    stop() {
      stopSampling?.();
      stopSampling = undefined;
      return sample;
    },
  };
}

async function installRowHoles(page: Page) {
  await page.addInitScript(defineRowHoles);
  await page.evaluate(defineRowHoles);
}

await requireBrowserLane("transcript-row-holes-browser.test.ts", async () => {
  const ENTRY = "agent-pane.transcript-row-holes";
  const VARIANT = "history";
  /// TranscriptRowHoles.gallery.ts TURNS and MIDDLE.
  const LAST = 11;
  const MIDDLE = 5;
  const WIDE = 900;
  const NARROW = 520;
  const HEIGHT = 700;
  const BLANK_LIMIT = 40;
  setDefaultTimeout(600_000);
  const launchOptions = process.env.CMUX_BROWSER_EXECUTABLE
    ? { executablePath: process.env.CMUX_BROWSER_EXECUTABLE }
    : {};
  try {
    await (await chromium.launch({ headless: true, ...launchOptions })).close();
  } catch {
    console.warn("transcript-row-holes-browser: skipping (run `bunx playwright install chromium`)");
    return;
  }
  const webviews = path.resolve(import.meta.dir, "..");
  const { createServer } = await import("vite");
  let vite: Awaited<ReturnType<typeof createServer>> | undefined;
  let browser: Browser | undefined;
  beforeAll(async () => {
    vite = await createServer({
      configFile: path.join(webviews, "vite.config.gallery-dev.ts"),
      server: { port: 0, host: "127.0.0.1", strictPort: false },
      logLevel: "error",
    });
    await vite.listen();
    browser = await chromium.launch({ headless: true, ...launchOptions });
    await warmGalleryFrame(vite, ENTRY, { browser, params: { variant: VARIANT } });
  });
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });

  /// The view at rest: no finite animation running, and the offset, height and mounted rows the same
  /// over ten painted frames in a row (the scroll lead lets go 120 ms after the last move).
  const settle = (page: Page) =>
    page.evaluate(
      () =>
        new Promise<void>((done, fail) => {
          let last = "";
          let alike = 0;
          let frames = 0;
          window.cmuxAfterPaint(() => {
            const scroller = document.querySelector<HTMLElement>(".acpmux-scroll");
            if (!scroller) return;
            const moving = document
              .getAnimations()
              .some(
                (animation) =>
                  animation.playState === "running" &&
                  Number.isFinite(animation.effect?.getComputedTiming().endTime ?? Infinity),
              );
            const mounted = [...scroller.querySelectorAll<HTMLElement>(".acpmux-row")]
              .map((row) => `${row.getAttribute("aria-posinset")}:${row.dataset.rowId}:${row.style.top}`)
              .join(",");
            const now = `${Math.round(scroller.scrollTop)} ${scroller.scrollHeight} ${scroller.clientHeight} ${mounted}`;
            alike = !moving && now === last ? alike + 1 : 0;
            last = now;
            if (alike >= 10) {
              done();
              return false;
            }
            frames += 1;
            if (frames > 900) {
              fail(new Error(`the view did not come to rest in 900 painted frames (moving: ${moving})`));
              return false;
            }
          });
        }),
    );

  async function open(): Promise<Page> {
    const port = (vite!.httpServer!.address() as { port: number }).port;
    const page = await browser!.newPage({ viewport: { width: WIDE, height: HEIGHT } });
    await installPaintedFrames(page);
    await installRowHoles(page);
    await page.addInitScript(() => localStorage.clear());
    await page.emulateMedia({ reducedMotion: "no-preference" });
    await page.goto(`http://127.0.0.1:${port}${galleryFrame(ENTRY, { variant: VARIANT })}`);
    await page.locator(`[data-row-id="worked-t${LAST}-user"]`).waitFor();
    await settle(page);
    return page;
  }

  /// Scrolls the row `id` to `offset` px under the view's top (paging up until it mounts).
  const bring = async (page: Page, id: string, offset = 40) => {
    for (let attempt = 0; attempt < 3; attempt += 1) {
      await page.evaluate(
        async ({ id, offset }) => {
          const scroller = document.querySelector<HTMLElement>(".acpmux-scroll")!;
          for (let step = 0; step < 80 && !document.querySelector(`[data-row-id="${id}"]`); step += 1) {
            scroller.scrollTop -= scroller.clientHeight / 2;
            await window.cmuxPaintFrame();
          }
          const node = document.querySelector<HTMLElement>(`[data-row-id="${id}"]`)!;
          scroller.scrollTop += node.getBoundingClientRect().top - scroller.getBoundingClientRect().top - offset;
        },
        { id, offset },
      );
      await settle(page);
    }
  };
  const toBottom = async (page: Page) => {
    await page.evaluate(async () => {
      const scroller = document.querySelector<HTMLElement>(".acpmux-scroll")!;
      for (let step = 0; step < 40; step += 1) {
        scroller.scrollTop = scroller.scrollHeight;
        await window.cmuxPaintFrame();
        if (scroller.scrollHeight - scroller.clientHeight - scroller.scrollTop < 1) break;
      }
    });
    await settle(page);
  };
  /// A disclosure is named `key:<row id>|<its label>`: the label stays as it opens and closes, where
  /// its index among the row's toggles moves as the toggles inside an opened one come and go.
  const toggle = (key: string) => key;
  /// The disclosures of turn `turn`'s opened fold, in order, between its "Worked for" line and its
  /// footer: every toggle there, each run, group, call and "Received N messages".
  const disclosures = (page: Page, turn: number) =>
    page.evaluate((turn) => {
      const worked = document.querySelector<HTMLElement>(`[data-row-id="worked-t${turn}-user"]`)!;
      const from = Number(worked.getAttribute("aria-posinset"));
      const keys: string[] = [];
      const rows = [...document.querySelectorAll<HTMLElement>("article.acpmux-row")].sort(
        (a, b) => Number(a.getAttribute("aria-posinset")) - Number(b.getAttribute("aria-posinset")),
      );
      for (const row of rows) {
        if (Number(row.getAttribute("aria-posinset")) <= from) continue;
        if (row.dataset.rowId?.startsWith(`t${turn + 1}-`) || row.dataset.rowId === `t${turn}-end`) break;
        for (const button of row.querySelectorAll<HTMLElement>("button[aria-expanded]")) {
          const label = (button.textContent ?? "").replace(/\s+/g, " ").trim().slice(0, 32);
          const key = `key:${row.dataset.rowId}|${label}`;
          if (label !== "" && !keys.includes(key)) keys.push(key);
        }
      }
      return keys;
    }, turn);
  /// Clicks the element `target` names where it is drawn, bringing it into view first.
  const click = async (page: Page, target: string) => {
    const box = await page.evaluate((target) => {
      let node: HTMLElement | null = null;
      if (!target.startsWith("key:")) node = document.querySelector<HTMLElement>(target);
      else {
        const [id, label] = target.slice(4).split("|") as [string, string];
        const row = document.querySelector<HTMLElement>(`[data-row-id="${id}"]`);
        node =
          [...(row?.querySelectorAll<HTMLElement>("button[aria-expanded]") ?? [])].find(
            (button) => (button.textContent ?? "").replace(/\s+/g, " ").trim().slice(0, 32) === label,
          ) ?? null;
      }
      const scroller = document.querySelector<HTMLElement>(".acpmux-scroll")!.getBoundingClientRect();
      if (!node) return undefined;
      const rect = node.getBoundingClientRect();
      return { x: rect.left + Math.min(24, rect.width / 2), y: rect.top + rect.height / 2, view: scroller };
    }, target);
    // A line the step before took away (a closed fold forgets the lines inside it): nothing to click.
    if (!box) {
      console.log(`row-holes: nothing matches ${target}`);
      return true;
    }
    if (box.y < box.view.top + 4 || box.y > box.view.bottom - 4) return false;
    await page.mouse.click(box.x, box.y);
    return true;
  };

  /// `scrolled`: the step scrolled the view itself (a toggle out of view brought in), so lines moving is
  /// the scroll, not a shift.
  type Step = { label: string; act: (page: Page) => Promise<void>; shiftFree?: string[]; scrolled?: boolean };
  /// Runs `step` under the frame sampler and returns the failures it shows.
  const measure = async (page: Page, mode: string, step: Step, track: Record<string, string>) => {
    await page.evaluate((track) => window.cmuxRowHoles.start(track), track);
    await step.act(page);
    await settle(page);
    const sample: RowSample = await page.evaluate(() => window.cmuxRowHoles.stop());
    const rest = await page.evaluate(() => window.cmuxRowHoles.read());
    const at = `${mode} / ${step.label}`;
    const failures: string[] = [];
    const resting = rest.holes.filter((hole) => hole.inView);
    for (const hole of resting)
      failures.push(
        `${at}: HOLE ${hole.hole}px between ${hole.above} and ${hole.below} at rest${hole.hole < 0 ? " (overlap)" : ""}`,
      );
    if (sample.worstBlank > BLANK_LIMIT)
      failures.push(`${at}: BLANK a ${sample.worstBlank}px uncovered band in a painted frame`);
    for (const leftover of rest.leftovers) failures.push(`${at}: LEFTOVER ${leftover}`);
    for (const name of step.scrolled ? [] : (step.shiftFree ?? []))
      if ((sample.moved[name] ?? 0) > 1) failures.push(`${at}: SHIFT ${name} moved ${sample.moved[name]}px`);
    console.log(
      `row-holes ${at}: ${sample.frames} frames, worst hole in motion ${
        sample.worstHole ? `${sample.worstHole.hole}px (${sample.worstHole.above} > ${sample.worstHole.below})` : "none"
      }, worst blank ${sample.worstBlank}px, at rest ${resting.length} holes${
        rest.holes.length > resting.length ? ` (+${rest.holes.length - resting.length} out of view)` : ""
      }, moved ${JSON.stringify(sample.moved)}`,
    );
    return failures;
  };

  /// Leo's combinations on turn `turn`'s opened "Worked for". `follow`: at the bottom, else scrolled up.
  async function walk(turn: number, follow: boolean): Promise<string[]> {
    const page = await open();
    const mode = follow ? "following the bottom" : "scrolled up";
    const worked = `worked-t${turn}-user`;
    const workedToggle = `[data-row-id="${worked}"] button.cv-worked`;
    const place = async () => (follow ? toBottom(page) : bring(page, worked));
    await place();
    const failures: string[] = [];
    const clicks = (label: string, selectors: () => string[], shiftFree = !follow): Step => {
      const step: Step = {
        label,
        shiftFree: shiftFree ? ["worked"] : undefined,
        act: async (page) => {
          for (const selector of selectors()) {
            if (!(await click(page, selector))) {
              // Out of view: bring its row in (the reader scrolls to it), then click.
              const id = selector.startsWith("key:")
                ? selector.slice(4).split("|")[0]!
                : /data-row-id="([^"]+)"/.exec(selector)![1]!;
              await bring(page, id, 160);
              step.scrolled = true;
              await click(page, selector);
            }
            await settle(page);
          }
        },
      };
      return step;
    };
    const track = { worked: workedToggle };
    failures.push(
      ...(await measure(
        page,
        mode,
        clicks("open Worked for", () => [workedToggle]),
        track,
      )),
    );
    const rows = await disclosures(page, turn);
    console.log(`row-holes ${mode}: disclosures in turn ${turn}: ${rows.join(", ")}`);
    expect(rows.length).toBeGreaterThanOrEqual(2);
    // Four of them, spread over the turn (the first, last and two between), repeating when it has fewer.
    const pick = (at: number) => rows[Math.min(rows.length - 1, Math.round((at * (rows.length - 1)) / 3))]!;
    const [a, b, c, d] = [pick(0), pick(1), pick(2), pick(3)];
    const steps: Step[] = [
      clicks("expand one", () => [toggle(a)]),
      clicks("expand several", () => [toggle(b), toggle(c), toggle(d)]),
      clicks("collapse one while others stay open", () => [toggle(b)]),
      clicks("collapse all", () => [toggle(a), toggle(c), toggle(d)]),
      clicks("expand several again", () => [toggle(a), toggle(b), toggle(c)]),
      {
        label: "scroll four views away and back",
        act: async (page) => {
          await page.evaluate(async () => {
            const scroller = document.querySelector<HTMLElement>(".acpmux-scroll")!;
            for (let step = 0; step < 8; step += 1) {
              scroller.scrollTop -= scroller.clientHeight / 2;
              await window.cmuxPaintFrame();
            }
          });
          await settle(page);
          const away = await page.evaluate(() => window.cmuxRowHoles.read());
          for (const hole of away.holes.filter((hole) => hole.inView))
            failures.push(`${mode} / scrolled away: HOLE ${hole.hole}px between ${hole.above} and ${hole.below}`);
          // Back as a reader scrolls: by half a view a frame.
          await page.evaluate(async () => {
            const scroller = document.querySelector<HTMLElement>(".acpmux-scroll")!;
            for (let step = 0; step < 8; step += 1) {
              scroller.scrollTop += scroller.clientHeight / 2;
              await window.cmuxPaintFrame();
            }
          });
          await settle(page);
          await place();
        },
      },
      {
        label: `narrow to ${NARROW}px and back`,
        act: async (page) => {
          await page.setViewportSize({ width: NARROW, height: HEIGHT });
          await settle(page);
          const narrow = await page.evaluate(() => window.cmuxRowHoles.read());
          for (const hole of narrow.holes.filter((hole) => hole.inView))
            failures.push(`${mode} / narrow: HOLE ${hole.hole}px between ${hole.above} and ${hole.below}`);
          await page.setViewportSize({ width: WIDE, height: HEIGHT });
          await settle(page);
          await place();
        },
      },
      clicks("close Worked for with rows open", () => [workedToggle]),
      clicks("open Worked for again", () => [workedToggle]),
      clicks("expand one after the reopen", () => [toggle(d)]),
    ];
    for (const step of steps) failures.push(...(await measure(page, mode, step, track)));
    await page.close();
    return failures;
  }

  test("following the bottom: no hole, blank band or leftover through every fold, scroll and width change", async () => {
    const failures = await walk(LAST, true);
    for (const failure of failures) console.log(`row-holes FAIL ${failure}`);
    expect(failures).toEqual([]);
  });

  test("scrolled up mid-history: no hole, blank band, shift or leftover through every fold, scroll and width change", async () => {
    const failures = await walk(MIDDLE, false);
    for (const failure of failures) console.log(`row-holes FAIL ${failure}`);
    expect(failures).toEqual([]);
  });
});
