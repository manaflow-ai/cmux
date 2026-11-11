// cmux-web-test-timeout: 600
// l10n-allow-file: test labels, not shipped UI.
// A status line that hands over to its next step shows words on every frame of the change, never two
// texts over each other, and its box never jumps (Leo, 2026-11-11: "the composer hat the way it
// switches between text is ugly bc it's too slow on the transitions and there's breif moments where it
// just looks like a blank tear that then switches"). Both lines that do it: the composer hat's header
// with one subagent (SubagentTray.tsx, `Tick` slide) and the running turn's live line (Thinking.tsx
// `useRoll`), on the gallery's agent-pane.status-swap stage, at rest and with a busy main thread (a
// long task every few frames, as a loaded Mac's page sees). Every painted frame is read as it paints
// (paintedFrames.ts):
// - words on every frame: the text drawn opaque enough to read (0.6) and unblurred, inside the line's
//   box, covers at least 90% of a line's height (a roll's middle, half of each line, does; a
//   cross-fade's middle, both texts faded, does not: that is the blank tear);
// - overlap: two readable texts drawn over the same pixels (more than 2px of y);
// - the line's box keeps its height;
// - the change ends within the motion scale's micro step plus a frame's slack.
//
// Real gallery frames in Chromium and WebKit from Playwright; CI fails the file when it cannot launch
// (requireBrowserLane).
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, webkit, type Browser, type BrowserType, type Page } from "playwright";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";
import { installPaintedFrames } from "./support/paintedFrames";
import { requireBrowserLane } from "./support/requireBrowserLane";

type LineReport = {
  frames: number;
  blank: number;
  overlap: number;
  heights: number[];
  swapMs: number[];
};
type Report = { hat: LineReport; line: LineReport };

await requireBrowserLane("status-swap-frames.test.ts", async () => {
  setDefaultTimeout(540_000);
  const ENTRY = "agent-pane.status-swap";
  const engines: [string, BrowserType][] = [];
  for (const engine of [
    ["chromium", chromium],
    ["webkit", webkit],
  ] as [string, BrowserType][]) {
    try {
      await (await engine[1].launch({ headless: true })).close();
      engines.push(engine);
    } catch {
      console.warn(`status-swap-frames: skipping ${engine[0]} (run \`bunx playwright install ${engine[0]}\`)`);
    }
  }
  if (engines.length === 0) {
    describe.skip("status swap frames", () => test("no engine", () => {}));
    return;
  }
  const webviews = path.resolve(import.meta.dir, "..");
  const { createServer } = await import("vite");
  let vite: Awaited<ReturnType<typeof createServer>> | undefined;
  const browsers = new Map<string, Browser>();

  beforeAll(async () => {
    vite = await createServer({
      configFile: path.join(webviews, "vite.config.gallery-dev.ts"),
      server: { port: 0, host: "127.0.0.1", strictPort: false },
      logLevel: "error",
    });
    await vite.listen();
    for (const [name, engine] of engines) browsers.set(name, await engine.launch({ headless: true }));
    await warmGalleryFrame(vite, [ENTRY], { browser: browsers.values().next().value });
  });
  afterAll(async () => {
    for (const browser of browsers.values()) await browser.close();
    await vite?.close();
  });

  async function open(name: string, variant = "at-rest"): Promise<Page> {
    const port = (vite!.httpServer!.address() as { port: number }).port;
    const page = await browsers.get(name)!.newPage({ viewport: { width: 760, height: 320 } });
    await installPaintedFrames(page);
    await page.goto(`http://127.0.0.1:${port}${galleryFrame(ENTRY, { variant })}`);
    await page.waitForFunction(() => document.documentElement.dataset.galleryReady === "1", undefined, {
      timeout: 90_000,
    });
    await page.locator(".acpmux-running-tray__latest").waitFor({ timeout: 30_000 });
    await page.locator('[data-status-swap="line"] .cv-thinking').waitFor({ timeout: 30_000 });
    return page;
  }

  /// Reads every painted frame of `changes` steps, `gap` ms apart, on both lines.
  const run = (page: Page, changes: number, gap: number) =>
    page.evaluate(
      async ([changes, gap]) => {
        type Line = { frames: number; blank: number; overlap: number; heights: number[]; swapMs: number[] };
        const fresh = (): Line => ({ frames: 0, blank: 0, overlap: 0, heights: [], swapMs: [] });
        const report = { hat: fresh(), line: fresh() };
        const blur = (style: CSSStyleDeclaration) => {
          const match = /blur\(([\d.]+)px\)/.exec(style.filter);
          return match ? Number(match[1]) : 0;
        };
        /// The texts drawn in a line and the box that bounds it.
        const parts = (which: "hat" | "line") => {
          if (which === "hat") {
            const cell = document.querySelector<HTMLElement>(".acpmux-running-tray__latest");
            return {
              box: cell,
              texts: cell ? [...cell.children].filter((node): node is HTMLElement => node instanceof HTMLElement) : [],
              outer: document.querySelector<HTMLElement>(".acpmux-running-tray__head"),
            };
          }
          const line = document.querySelector<HTMLElement>('[data-status-swap="line"] .cv-worked--live');
          const row = line?.querySelector<HTMLElement>(".cv-shimmer__row") ?? null;
          return {
            box: line,
            texts: row
              ? ([row.querySelector(".cv-roll-out"), row.querySelector(".cv-thinking")].filter(
                  (node): node is HTMLElement => node instanceof HTMLElement,
                ) as HTMLElement[])
              : [],
            outer: line,
          };
        };
        /// The part of `text` drawn opaque enough to read (0.6) and unblurred, inside the line's box,
        /// as a span of y; undefined when none is.
        const legible = (text: HTMLElement, box: DOMRect) => {
          const style = getComputedStyle(text);
          if (style.display === "none" || style.visibility === "hidden") return undefined;
          // The drawn opacity: the text's own times each ancestor's (a fade on either).
          let opacity = 1;
          for (let node: HTMLElement | null = text; node && node !== document.body; node = node.parentElement)
            opacity *= Number(getComputedStyle(node).opacity);
          if (opacity < 0.6 || blur(style) > 0.5) return undefined;
          const rect = text.getBoundingClientRect();
          if (rect.height <= 0 || rect.width <= 0) return undefined;
          const top = Math.max(rect.top, box.top);
          const bottom = Math.min(rect.bottom, box.bottom);
          return bottom > top ? { top, bottom, height: Math.min(rect.height, box.height) } : undefined;
        };
        const read = () => {
          for (const which of ["hat", "line"] as const) {
            const { box, texts, outer } = parts(which);
            const line = report[which];
            line.frames += 1;
            if (!box) {
              line.blank += 1;
              continue;
            }
            const bounds = box.getBoundingClientRect();
            const shown = texts.flatMap((text) => {
              const span = legible(text, bounds);
              return span ? [span] : [];
            });
            // Blank: the readable words cover less than 90% of a line's height (a cross-fade's middle,
            // both texts faded; or nothing drawn). A roll's middle, half of each line, covers it all.
            const covered = (() => {
              const spans = [...shown].sort((a, b) => a.top - b.top);
              let total = 0;
              let reach = -Infinity;
              for (const span of spans) {
                total += Math.max(0, span.bottom - Math.max(span.top, reach));
                reach = Math.max(reach, span.bottom);
              }
              return total;
            })();
            const lineHeight = Math.max(0, ...shown.map((span) => span.height));
            if (shown.length === 0 || covered < 0.9 * lineHeight) line.blank += 1;
            // Overlap: two readable texts drawn over the same pixels.
            for (let a = 0; a < shown.length; a++)
              for (let b = a + 1; b < shown.length; b++) {
                const cross = Math.min(shown[a]!.bottom, shown[b]!.bottom) - Math.max(shown[a]!.top, shown[b]!.top);
                if (cross > 2) {
                  line.overlap += 1;
                  a = shown.length;
                  break;
                }
              }
            const height = Math.round((outer ?? box).getBoundingClientRect().height * 10) / 10;
            if (!line.heights.includes(height)) line.heights.push(height);
          }
        };
        /// The finite animations playing in a line (its shimmer and spinner loop forever).
        const playing = (which: "hat" | "line") => {
          const { outer } = parts(which);
          return (outer?.getAnimations({ subtree: true }) ?? []).filter(
            (animation) => animation.playState === "running" && animation.effect?.getTiming().iterations !== Infinity,
          ).length;
        };
        const stop = window.cmuxAfterPaint(read);
        const button = document.querySelector<HTMLElement>('[data-stage="next"]')!;
        for (let change = 0; change < changes; change++) {
          const started = performance.now();
          const ended = { hat: -1, line: -1 };
          button.click();
          for (let frame = 0; frame < 120; frame++) {
            const at = await window.cmuxPaintFrame();
            for (const which of ["hat", "line"] as const)
              if (ended[which] < 0 && playing(which) === 0) ended[which] = at - started;
            if (ended.hat >= 0 && ended.line >= 0 && at - started >= gap) break;
          }
          for (const which of ["hat", "line"] as const) report[which].swapMs.push(Math.round(ended[which]));
        }
        stop();
        return report;
      },
      [changes, gap] as const,
    );

  /// A busy main thread: a long task of `busy` ms every `every` ms.
  const lag = (page: Page, busy: number, every: number) =>
    page.evaluate(
      ([busy, every]) => {
        window.setInterval(() => {
          const until = performance.now() + busy;
          while (performance.now() < until) {
            /* busy */
          }
        }, every);
      },
      [busy, every] as const,
    );

  for (const [name] of engines)
    for (const lagging of [false, true])
      test(`${name}${lagging ? ", lagging" : ""}: every frame of a status change shows one line of words`, async () => {
        const page = await open(name);
        if (lagging) await lag(page, 40, 70);
        const report: Report = await run(page, 8, 260);
        console.log(`STATUS_SWAP_REPORT ${JSON.stringify({ engine: name, lagging, ...report })}`);
        await page.close();
        for (const which of ["hat", "line"] as const) {
          const line = report[which];
          expect(line.frames, `${which}: frames read`).toBeGreaterThan(20);
          expect({ which, blank: line.blank, overlap: line.overlap }).toEqual({ which, blank: 0, overlap: 0 });
          // The line's box never jumps while its words change.
          expect(
            Math.max(...line.heights) - Math.min(...line.heights),
            `${which}: heights ${line.heights.join(", ")}`,
          ).toBeLessThanOrEqual(0.5);
          // Each change ends within the micro step plus two frames of slack, at rest.
          if (!lagging)
            for (const ms of line.swapMs) expect(ms, `${which}: change took ${ms}ms`).toBeLessThanOrEqual(160);
        }
      });

  // Leo's recording (2026-11-11): "Thinking 1m · 1.7K tokens" turns to "Sending a message 1m · 1.7K
  // tokens" and back to "Thinking 1m 5s · 2.5K tokens". The whole line rolls as one: on no frame does
  // its time or token count appear, vanish or slide sideways at once (a pop: the set of counts drawn
  // changed, or one moved more than 1px, in a frame where nothing on the line was rolling), and every
  // frame shows words (the checks above).
  for (const [name] of engines)
    test(`${name}: Leo's Thinking, Sending a message, Thinking rolls as one line`, async () => {
      const page = await open(name, "leo-sequence");
      const report = await page.evaluate(async () => {
        const line = () => document.querySelector<HTMLElement>('[data-status-swap="line"] .cv-worked--live');
        type Seen = { counts: string[]; left: number[] };
        let last: Seen | undefined;
        const labels: string[] = [];
        let pops = 0;
        let frames = 0;
        const examples: string[] = [];
        const read = () => {
          const node = line();
          if (!node) return;
          frames += 1;
          const counts = [...node.querySelectorAll<HTMLElement>(":scope > .cv-worked__count")];
          const moving = (element: Element) =>
            element
              .getAnimations()
              .some(
                (animation) =>
                  animation.playState === "running" && animation.effect?.getTiming().iterations !== Infinity,
              );
          const seen = {
            counts: counts.map((count) => (count.textContent ?? "").replace(/[\d.]+K?/g, "#").trim()),
            left: counts.map((count) => Math.round(count.getBoundingClientRect().left)),
          };
          const text = node.querySelector(".cv-thinking")?.textContent ?? "";
          const label = /Sending a message/.test(text)
            ? "Sending a message"
            : /Thinking/.test(text)
              ? "Thinking"
              : text;
          if (labels.at(-1) !== label) labels.push(label);
          if (last) {
            const before = last;
            // A count that slid sideways with no motion of its own, one that came with none, or one
            // that went with no old copy rolling it out.
            const slid = counts.some(
              (count, index) =>
                Math.abs(seen.left[index]! - (before.left[index] ?? seen.left[index]!)) > 1 && !moving(count),
            );
            const came =
              counts.length > before.counts.length &&
              counts.slice(before.counts.length).some((count) => !moving(count));
            const went = counts.length < before.counts.length && !node.querySelector(".cv-roll-out[data-tail]");
            if (slid || came || went) {
              pops += 1;
              if (examples.length < 6)
                examples.push(
                  `${slid ? "slid" : came ? "came" : "went"} at frame ${frames} (${label}): ${before.counts.join("|")} ${before.left.join(",")} -> ${seen.counts.join("|")} ${seen.left.join(",")}`,
                );
            }
          }
          last = seen;
        };
        // The line as the stage first draws it: Leo's sequence starts on "Thinking".
        read();
        const stop = window.cmuxAfterPaint(read);
        const button = document.querySelector<HTMLElement>('[data-stage="next"]')!;
        for (let change = 0; change < 3; change++) {
          button.click();
          for (let frame = 0; frame < 24; frame++) await window.cmuxPaintFrame();
        }
        stop();
        return { frames, labels, pops, examples };
      });
      console.log(`STATUS_SEQUENCE_REPORT ${JSON.stringify({ engine: name, ...report })}`);
      await page.close();
      // The stage's three steps from its first, then the first again: Thinking (1.7K), Sending a
      // message, Thinking (2.5K), Thinking (1.7K, the same words: only the count changes).
      expect(report.labels).toEqual(["Thinking", "Sending a message", "Thinking"]);
      expect({ pops: report.pops, examples: report.examples }).toEqual({ pops: 0, examples: [] });
    });
});
