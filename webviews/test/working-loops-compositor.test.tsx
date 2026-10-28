// l10n-allow-file: test fixtures, not shipped UI.
// SPINNERS-OFF-MAIN (Lawrence 2026-10-21: "for the loading spinners, is it running on main thread?
// should it be or is it wasteful in terms of cpu?"). The chat's loops that run while an agent works
// (the "Thinking" line's shimmer, a row's spinner ring and breathing dot) animate only `transform` and
// `opacity`, which the engine's compositor runs on its own: the page's main thread paints nothing per
// frame. A loop on `background-position` (the old shimmer) repaints its text every frame on the page's
// main thread. Read from the real stylesheets and the real components in Chromium and WebKit; the
// shimmer still moves, the label still reads once, and Reduce Motion stops every loop.
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import { fixedPageClock } from "../src/ui/fixedPageClock";
import { readFileSync } from "node:fs";
import path from "node:path";
import { renderToStaticMarkup } from "react-dom/server";
import { chromium, webkit, type Browser, type BrowserType, type Page } from "playwright";
import { Spinner } from "../src/agent-session/acpmux/conversation/icons";
import { Thinking } from "../src/agent-session/acpmux/conversation/Thinking";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("working-loops-compositor.test.tsx", async () => {
  setDefaultTimeout(60_000);
  const src = path.resolve(import.meta.dir, "../src");
  const css = [
    "pages/shared/desktop.css",
    "agent-session/shared/styles.css",
    "agent-session/acpmux/styles.css",
    "agent-session/acpmux/conversation/conversation.css",
  ]
    .map((file) => readFileSync(path.join(src, file), "utf8"))
    .join("\n");
  const START = Date.UTC(2026, 9, 21, 9, 0, 0);
  const markup = renderToStaticMarkup(
    <div>
      <div id="thinking">
        <Thinking since={START} clock={fixedPageClock(START + 18_000)} below />
      </div>
      <span id="ring">
        <Spinner loading />
      </span>
      <span id="dot">
        <Spinner />
      </span>
    </div>,
  );
  /** Properties the compositor animates without the page's main thread (plus keyframe bookkeeping). */
  const COMPOSITED = new Set([
    "transform",
    "opacity",
    "translate",
    "rotate",
    "scale",
    "offset",
    "easing",
    "composite",
    "computedOffset",
  ]);

  for (const [engine, type] of [
    ["chromium", chromium],
    ["webkit", webkit],
  ] as [string, BrowserType][]) {
    describe(`working loops run on the compositor (${engine})`, () => {
      let browser: Browser | undefined;
      beforeAll(async () => {
        // Bounded: on some fleet workers WebKit's launch hangs; then this engine's half warns and skips.
        browser = await type.launch({ headless: true, timeout: 30_000 }).catch((error) => {
          console.warn(`working-loops-compositor: ${engine} did not launch: ${String(error).slice(0, 200)}`);
          return undefined;
        });
      });
      afterAll(async () => {
        // WebKit's close can hang on the fleet with loops still running; the pages are closed.
        // fixed-wait: a bounded wait for a close that has no completion signal when it hangs.
        await Promise.race([browser?.close(), new Promise((resolve) => setTimeout(resolve, 5000))]);
      });

      async function open(reducedMotion: "reduce" | "no-preference"): Promise<Page> {
        const page = await browser!.newPage();
        await page.emulateMedia({ reducedMotion });
        await page.setContent(
          `<html style="--agent-text: rgb(230,230,230); --agent-muted: rgb(160,160,170)">` +
            `<head><style>${css}</style></head>` +
            `<body>${markup}</body></html>`,
        );
        await page.evaluate(
          () => new Promise((resolve) => requestAnimationFrame(() => requestAnimationFrame(resolve))),
        );
        return page;
      }

      /** Each running loop: where it runs and the properties its keyframes animate. */
      const loops = (page: Page) =>
        page.evaluate(() =>
          document
            .getAnimations()
            .filter((animation) => animation.playState === "running")
            .map((animation) => {
              const effect = animation.effect as KeyframeEffect;
              const target = effect.target as Element;
              const host = target.closest("#thinking, #ring, #dot");
              return {
                name: (animation as CSSAnimation).animationName,
                host: host?.id ?? "?",
                // An SVG shape inside an <svg> gets no layer of its own: its loop repaints the svg.
                svgShape: target instanceof SVGElement && target.ownerSVGElement !== null,
                properties: [...new Set(effect.getKeyframes().flatMap((frame) => Object.keys(frame)))],
              };
            }),
        );

      test("every running loop animates only transform and opacity", async () => {
        if (!browser) return console.warn(`working-loops-compositor: ${engine} did not launch`);
        const page = await open("no-preference");
        try {
          const running = await loops(page);
          // The Thinking line shimmers, the loading ring turns and the working dot breathes.
          expect(new Set(running.map((loop) => loop.host))).toEqual(new Set(["thinking", "ring", "dot"]));
          for (const loop of running) {
            const painted = loop.properties.filter((property) => !COMPOSITED.has(property));
            expect({ loop: `${loop.host} ${loop.name}`, painted, svgShape: loop.svgShape }).toEqual({
              loop: `${loop.host} ${loop.name}`,
              painted: [],
              svgShape: false,
            });
          }
        } finally {
          await page.close();
        }
      });

      test("the shimmering line still reads its label once", async () => {
        if (!browser) return;
        const page = await open("no-preference");
        try {
          const read = await page.evaluate(() => {
            // What assistive tech and copy read: the text outside aria-hidden copies.
            const clone = document.querySelector("#thinking .cv-thinking")!.cloneNode(true) as Element;
            clone.querySelectorAll("[aria-hidden='true']").forEach((node) => node.remove());
            return { text: clone.textContent };
          });
          expect(read.text).toBe("Thinking");
        } finally {
          await page.close();
        }
      });

      test("Reduce Motion stops every loop", async () => {
        if (!browser) return;
        const page = await open("reduce");
        try {
          expect(await loops(page)).toEqual([]);
        } finally {
          await page.close();
        }
      });
    });
  }
});
