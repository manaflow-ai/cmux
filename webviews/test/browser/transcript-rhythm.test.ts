import { afterAll, beforeAll, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { mkdir } from "node:fs/promises";
import { chromium, type Browser } from "playwright";
import { galleryFrame, warmGalleryFrame } from "../support/galleryFrame";
import { requireBrowserLane } from "../support/requireBrowserLane";

await requireBrowserLane("transcript-rhythm.test.ts", async () => {
  setDefaultTimeout(120_000);
  const webviews = path.resolve(import.meta.dir, "../..");
  const { createServer } = await import("vite");
  let vite: Awaited<ReturnType<typeof createServer>>;
  let browser: Browser;
  beforeAll(async () => {
    vite = await createServer({
      configFile: path.join(webviews, "vite.config.gallery-dev.ts"),
      server: { port: 0, host: "127.0.0.1" },
      logLevel: "error",
    });
    await vite.listen();
    browser = await chromium.launch({ headless: true });
    await warmGalleryFrame(vite, "agent-pane.transcript", { browser, params: { variant: "grid-rhythm" } });
  });
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });
  for (const width of [480, 1000])
    for (const theme of ["light", "dark"]) {
      test(`${theme} ${width}px: transcript column and block rhythm survive hover`, async () => {
        const page = await browser.newPage({ viewport: { width, height: 900 } });
        try {
          const port = (vite.httpServer!.address() as { port: number }).port;
          await page.goto(
            `http://127.0.0.1:${port}${galleryFrame("agent-pane.transcript", {
              variant: "grid-rhythm",
              theme: theme === "light" ? "Apple System Colors Light" : "Apple System Colors",
              colorScheme: theme,
            })}`,
          );
          await page.locator('[data-row-id="grid-message"] .cv-md').waitFor();
          await page.evaluate(() => document.fonts.ready);
          await page.evaluate(
            () => new Promise<void>((resolve) => requestAnimationFrame(() => requestAnimationFrame(() => resolve()))),
          );
          const measure = () =>
            page.evaluate(() => {
              const rect = (selector: string) => {
                const el = document.querySelector(selector);
                if (!el) throw new Error(`Missing rhythm element: ${selector}`);
                const r = el.getBoundingClientRect();
                return { left: r.left, right: r.right, top: r.top, bottom: r.bottom, height: r.height };
              };
              const header = rect('[data-row-id="grid-header"] .cv-disclosure__line');
              const prompt = rect('[data-row-id="grid-prompt"] .cv-user__bubble');
              const message = rect('[data-row-id="grid-message"] .cv-md');
              const group = rect(".acpmux-activity .cv-tools > .cv-tool");
              const live = rect(
                ".acpmux-thinking .cv-worked, .acpmux-working .cv-worked, .acpmux-activityLine .cv-activity",
              );
              const composer = rect(".acpmux-composer-box");
              const headerIcon = rect('[data-row-id="grid-header"] .cv-disclosure__icon');
              const toolIcon = rect(".acpmux-activity .cv-tool__icon");
              const chevron = rect(".acpmux-activity .cv-tool__chevron");
              const copy = rect('[data-row-id="grid-message"] .cv-reply-actions .cv-iconbtn svg');
              const paragraphs = [...document.querySelectorAll('[data-row-id="grid-message"] .cv-md > .cv-p')].map(
                (el) => el.getBoundingClientRect(),
              );
              return {
                header,
                prompt,
                turn: header.top - prompt.bottom,
                actionMid: (copy.top + copy.bottom) / 2 - message.bottom,
                message,
                group,
                live,
                composer,
                headerIcon,
                toolIcon,
                chevron,
                copy,
                gaps: [message.top - header.bottom, group.top - message.bottom, live.top - group.bottom],
                inner: paragraphs[1]!.top - paragraphs[0]!.bottom,
                composerGap: composer.top - live.bottom,
              };
            });
          await page.mouse.move(0, 0);
          const hidden = await measure();
          await page.locator('[data-row-id="grid-message"] .cv-md').hover();
          const shown = await measure();
          for (const [state, data] of Object.entries({ hidden, shown }))
            for (const [metric, value] of Object.entries(data))
              console.log(`TRANSCRIPT_RHYTHM ${JSON.stringify({ width, theme, state, metric, value })}`);
          if (process.env.CMUX_RHYTHM_CAPTURES) {
            await mkdir(process.env.CMUX_RHYTHM_CAPTURES, { recursive: true });
            const capture = await page.screenshot({
              path: `${process.env.CMUX_RHYTHM_CAPTURES}/${theme}-${width}.png`,
            });
            if (process.env.CMUX_RHYTHM_CAPTURE_LOG) {
              const encoded = capture.toString("base64");
              for (let offset = 0; offset < encoded.length; offset += 400)
                console.log(`RHYTHM_PNG ${theme}-${width} ${offset} ${encoded.slice(offset, offset + 400)}`);
            }
          }
          for (const state of [hidden, shown]) {
            expect(Math.abs(state.turn - 32), "turn gap").toBeLessThanOrEqual(0.5);
            expect(Math.abs(state.actionMid - 12), "action glyph center in block gap").toBeLessThanOrEqual(0.5);
            for (const gap of state.gaps) expect(Math.abs(gap - 24), "block gap").toBeLessThanOrEqual(0.5);
            expect(Math.abs(state.inner - 12), "paragraph gap").toBeLessThanOrEqual(0.5);
            expect(Math.abs(state.composerGap - 16), "composer gap").toBeLessThanOrEqual(0.5);
            for (const box of [state.message, state.headerIcon, state.toolIcon, state.live, state.copy]) {
              expect(Math.abs(box.left - state.composer.left), "col-left").toBeLessThanOrEqual(0.5);
            }
            expect(Math.abs(state.chevron.right - state.composer.right), "col-right").toBeLessThanOrEqual(0.5);
          }
          expect(shown).toEqual(hidden);
        } finally {
          await page.close();
        }
      });
    }
  for (const width of [480, 1000])
    for (const theme of ["light", "dark"])
      test(`${theme} ${width}px: opened cards share lines and count spacing`, async () => {
        const page = await browser.newPage({ viewport: { width, height: 900 } });
        try {
          const port = (vite.httpServer!.address() as { port: number }).port;
          await page.goto(
            `http://127.0.0.1:${port}${galleryFrame("agent-pane.transcript-grid-cards", {
              variant: "grid",
              theme: theme === "light" ? "Apple System Colors Light" : "Apple System Colors",
            })}`,
          );
          await page.locator(".cv-agentmsg__card").waitFor();
          await page.evaluate(() => document.fonts.ready);
          const measured = await page.evaluate(() => {
            const box = (s: string) => {
              const el = document.querySelector(s);
              if (!el) throw new Error(`Missing grid card: ${s}`);
              const r = el.getBoundingClientRect();
              return { left: r.left, right: r.right, top: r.top, bottom: r.bottom };
            };
            const column = box(".transcript-grid-cards > .cv-tools");
            const result: Record<string, number> = {};
            for (const [name, selector] of Object.entries({
              message: ".cv-agentmsg__icon",
              subsession: ".cv-disclosure__icon",
            }))
              result[`${name}/lead`] = box(selector).left - column.left;
            const message = box(".cv-agentmsg__card");
            result["message/text"] =
              message.left +
              parseFloat(getComputedStyle(document.querySelector(".cv-agentmsg__card")!).paddingLeft) -
              column.left;
            result["message/gap"] = message.top - box(".cv-agentmsg__line").bottom;
            result["message/under-gap"] = box(".cv-agentmsg__under").top - message.bottom;
            for (const [name, selector] of Object.entries({
              message: ".cv-agentmsg__toggle > .cv-tool__chevron",
              subsession: ".cv-disclosure__toggle > .cv-rotor",
              group: "[data-grid-count] .cv-tool__chevron",
            }))
              result[`${name}/trail`] = box(selector).right - column.right;
            const panel = box(".cv-disclosure__panel");
            result["subsession/nesting"] = panel.left - column.left;
            const card = box(".cv-agent-card");
            result["card/lead"] = box(".cv-agent-card__icon").left - card.left;
            result["card/text"] = box(".cv-agent-card__name").left - card.left;
            result["card/body"] =
              box(".cv-agent-card__doing").left +
              parseFloat(getComputedStyle(document.querySelector(".cv-agent-card__doing")!).paddingLeft) -
              card.left;
            for (const count of [2, 12]) {
              const root = `[data-grid-count="${count}"]`;
              result[`count-${count}/gap`] =
                box(`${root} .cv-tool-label__subject`).left - box(`${root} .cv-tool__verb`).right;
              result[`count-${count}/trail`] = box(`${root} .cv-tool__chevron`).right - column.right;
              if (
                getComputedStyle(document.querySelector(`${root} .cv-tool-label__subject`)!).fontVariantNumeric !==
                "tabular-nums"
              )
                throw new Error("Counts must use tabular numerals");
            }
            return result;
          });
          console.log(`TRANSCRIPT_CARDS ${JSON.stringify({ width, theme, measured })}`);
          for (const [line, actual] of Object.entries(measured)) {
            const expected =
              line === "message/text"
                ? 24
                : line === "subsession/nesting"
                  ? 16
                  : line === "card/lead" || line.endsWith("/under-gap") || line === "message/gap"
                    ? 12
                    : line === "card/text" || line === "card/body"
                      ? 36
                      : line.endsWith("/gap")
                        ? 8
                        : 0;
            expect(Math.abs(actual - expected), line).toBeLessThanOrEqual(0.5);
          }
        } finally {
          await page.close();
        }
      });
});
