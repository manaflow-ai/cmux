import { afterAll, beforeAll, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { mkdir } from "node:fs/promises";
import { chromium, type Browser } from "playwright";
import { galleryFrame, warmGalleryFrame } from "../support/galleryFrame";
import { REST_GAP } from "../../src/agent-session/acpmux/model";
import { restBand } from "../../src/agent-session/acpmux/transcriptGrid";
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
  // Every width and theme at the default Interface Size, and one at the largest (the gaps scale
  // with --cmux-interface-scale, in the CSS tokens and in the virtual placement alike).
  const rhythmCases: [number, string, number][] = [
    [480, "light", 1],
    [480, "dark", 1],
    [1000, "light", 1],
    [1000, "dark", 1],
    [1000, "light", 1.25],
  ];
  for (const [width, theme, scale] of rhythmCases) {
    test(`${theme} ${width}px${scale === 1 ? "" : ` at ${scale}x interface`}: transcript column and block rhythm survive hover`, async () => {
      const page = await browser.newPage({ viewport: { width, height: 900 } });
      try {
        const port = (vite.httpServer!.address() as { port: number }).port;
        await page.goto(
          `http://127.0.0.1:${port}${galleryFrame("agent-pane.transcript", {
            variant: "grid-rhythm",
            theme: theme === "light" ? "Apple System Colors Light" : "Apple System Colors",
            colorScheme: theme,
            interfaceScale: scale === 1 ? undefined : scale,
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
            // A received message's line leads with its sender (IncomingMessageCard.tsx `leading`).
            const headerIcon = rect('[data-row-id="grid-header"] .cv-disclosure__line > :first-child');
            const toolIcon = rect(".acpmux-activity .cv-tool__icon");
            const chevron = rect(".acpmux-activity .cv-tool__chevron");
            // A reply's own action row, when it draws one: a turn's copy now lives in its footer
            // (model.ts `hasReplyActions`), so the reply in this scene may have none.
            const copyEl = document.querySelector('[data-row-id="grid-message"] .cv-reply-actions .cv-iconbtn svg');
            const copy = copyEl ? rect('[data-row-id="grid-message"] .cv-reply-actions .cv-iconbtn svg') : undefined;
            const composerBox = document.querySelector(".acpmux-composer-box")!.getBoundingClientRect();
            // Every tool row's disclosure caret (inline after its label, cmux#28018).
            const chevronCenters = [
              ...document.querySelectorAll(".acpmux-row :is(.cv-tool__chevron, .cv-disclosure__line .cv-rotor)"),
            ].map((el) => {
              const r = el.getBoundingClientRect();
              return composerBox.right - (r.left + r.right) / 2;
            });
            // Every non-prompt block's first glyph or 16 icon box on col-left: no extra indents.
            const firstInk = [...document.querySelectorAll(".acpmux-row")]
              .filter((row) => !row.classList.contains("acpmux-user") && row.getBoundingClientRect().height > 0)
              .map((row) => {
                const lead = row.querySelector(
                  ".cv-tool__icon, .cv-disclosure__line > :first-child, .cv-md > :first-child, .cv-worked, .cv-activity",
                );
                return {
                  id: row.getAttribute("data-row-id") ?? row.className,
                  left: lead ? lead.getBoundingClientRect().left - composerBox.left : Number.NaN,
                };
              });
            const paragraphs = [...document.querySelectorAll('[data-row-id="grid-message"] .cv-md > .cv-p')].map((el) =>
              el.getBoundingClientRect(),
            );
            return {
              header,
              prompt,
              turn: header.top - prompt.bottom,
              actionMid: copy ? (copy.top + copy.bottom) / 2 - message.bottom : undefined,
              message,
              group,
              live,
              composer,
              headerIcon,
              toolIcon,
              chevron,
              copy,
              gaps: [message.top - header.bottom, group.top - message.bottom],
              // The live line is one more line of the tool run over it: flush (#29965).
              liveUnderRun: live.top - group.bottom,
              inner: paragraphs[1]!.top - paragraphs[0]!.bottom,
              composerGap: composer.top - live.bottom,
              floating: Boolean(document.querySelector(".acpmux-main[data-dock=float]")),
              chevronCenters,
              firstInk,
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
          await page.screenshot({
            path: `${process.env.CMUX_RHYTHM_CAPTURES}/${theme}-${width}${scale === 1 ? "" : `-${scale}x`}.png`,
          });
        }
        for (const state of [hidden, shown]) {
          expect(Math.abs(state.turn - 32 * scale), "turn gap").toBeLessThanOrEqual(0.5);
          if (state.actionMid !== undefined)
            expect(Math.abs(state.actionMid - 12 * scale), "action glyph center in block gap").toBeLessThanOrEqual(0.5);
          for (const gap of state.gaps) expect(Math.abs(gap - 24 * scale), "block gap").toBeLessThanOrEqual(0.5);
          expect(Math.abs(state.liveUnderRun), "live line flush under its run").toBeLessThanOrEqual(0.5);
          expect(Math.abs(state.inner - 12 * scale), "paragraph gap").toBeLessThanOrEqual(0.5);
          // Over a floating stack the newest line rests the rest gap over it (model.ts REST_GAP, Leo
          // 2026-11-01: "more space between composer and latest messages"); docked in flow, the
          // composer gap.
          expect(
            Math.abs(state.composerGap - (state.floating ? REST_GAP : 16 * scale)),
            "composer gap",
          ).toBeLessThanOrEqual(0.5);
          for (const box of [
            state.message,
            state.headerIcon,
            state.toolIcon,
            state.live,
            ...(state.copy ? [state.copy] : []),
          ]) {
            expect(Math.abs(box.left - state.composer.left), "col-left").toBeLessThanOrEqual(0.5);
          }
          // Disclosure carets sit right after their label, not on col-right (cmux#28018, Leo,
          // 2026-10-31: "we can fit stuff closer"); this test checks only that one is drawn.
          expect(state.chevronCenters.length, "tool chevrons").toBeGreaterThan(0);
          for (const ink of state.firstInk)
            expect(Math.abs(ink.left), `first ink on col-left: ${ink.id}`).toBeLessThanOrEqual(0.5);
        }
        expect(shown).toEqual(hidden);
      } finally {
        await page.close();
      }
    });
  }
  const openScene = async (entry: string, variant: string, width: number, theme: string) => {
    const page = await browser.newPage({ viewport: { width, height: 900 } });
    const port = (vite.httpServer!.address() as { port: number }).port;
    await page.goto(
      `http://127.0.0.1:${port}${galleryFrame(entry, {
        variant,
        theme: theme === "light" ? "Apple System Colors Light" : "Apple System Colors",
        colorScheme: theme,
      })}`,
    );
    await page.locator(".acpmux-composer-box").first().waitFor();
    await page.evaluate(() => document.fonts.ready);
    await page.evaluate(
      () => new Promise<void>((resolve) => requestAnimationFrame(() => requestAnimationFrame(() => resolve()))),
    );
    return page;
  };
  const shot = async (page: import("playwright").Page, name: string) => {
    if (!process.env.CMUX_RHYTHM_CAPTURES) return;
    await mkdir(process.env.CMUX_RHYTHM_CAPTURES, { recursive: true });
    await page.screenshot({ path: `${process.env.CMUX_RHYTHM_CAPTURES}/${name}.png` });
  };
  const rectOf = (page: import("playwright").Page, selector: string) =>
    page.evaluate((s) => {
      const el = document.querySelector(s);
      if (!el) throw new Error(`Missing rhythm element: ${s}`);
      const r = el.getBoundingClientRect();
      return { left: r.left, right: r.right, top: r.top, bottom: r.bottom };
    }, selector);
  for (const width of [480, 1000])
    for (const theme of ["light", "dark"]) {
      test(`${theme} ${width}px: the waiting indicator sits centred between its prompt and the composer`, async () => {
        const page = await openScene("agent-pane.transcript", "grid-waiting", width, theme);
        try {
          const prompt = await rectOf(page, '[data-row-id="grid-prompt"] .cv-user__bubble');
          const indicator = await rectOf(page, ":is(.acpmux-thinking, .acpmux-working) .cv-worked");
          const composer = await rectOf(page, ".acpmux-composer-box");
          const above = indicator.top - prompt.bottom;
          const below = composer.top - indicator.bottom;
          const floating = await page.evaluate(() => Boolean(document.querySelector(".acpmux-main[data-dock=float]")));
          console.log(`TRANSCRIPT_WAITING ${JSON.stringify({ width, theme, above, below })}`);
          await shot(page, `waiting-${theme}-${width}`);
          expect(Math.abs(above - 24), "block gap above the waiting indicator").toBeLessThanOrEqual(0.5);
          // Over a floating stack the indicator, the newest line, rests the rest gap over it.
          expect(Math.abs(below - (floating ? REST_GAP : 24)), "gap below the waiting indicator").toBeLessThanOrEqual(
            0.5,
          );
        } finally {
          await page.close();
        }
      });
      test(`${theme} ${width}px: a message above the composer keeps 24 and room for its action row`, async () => {
        const page = await openScene("agent-pane.transcript", "grid-settled", width, theme);
        try {
          const message = await rectOf(page, '[data-row-id="grid-message"] .cv-md');
          const composer = await rectOf(page, ".acpmux-composer-box");
          await page.locator('[data-row-id="grid-message"] .cv-md').hover();
          const shown = await page
            .waitForFunction(
              () =>
                [...document.querySelectorAll(".cv-reply-actions, .cv-turn-actions")].some(
                  (el) => getComputedStyle(el).opacity === "1",
                ),
              undefined,
              { timeout: 5_000 },
            )
            .then(() => true)
            .catch(() => false);
          if (!shown)
            throw new Error(
              `No action row shown: ${await page.evaluate(() =>
                JSON.stringify(
                  [...document.querySelectorAll(".acpmux-row")].map((row) => ({
                    id: row.getAttribute("data-row-id"),
                    cls: row.className,
                    revealed: row.hasAttribute("data-turn-revealed"),
                    actions: [...row.querySelectorAll(".cv-reply-actions, .cv-turn-actions")].map(
                      (el) => getComputedStyle(el).opacity,
                    ),
                  })),
                ),
              )}`,
            );
          const glyph = await rectOf(
            page,
            ':is([data-row-id="grid-message"] .cv-reply-actions, .acpmux-turnSummary .cv-turn-actions) svg',
          );
          const after = await rectOf(page, '[data-row-id="grid-message"] .cv-md');
          const gap = composer.top - message.bottom;
          const floating = await page.evaluate(() => Boolean(document.querySelector(".acpmux-main[data-dock=float]")));
          console.log(
            `TRANSCRIPT_SETTLED ${JSON.stringify({ width, theme, gap, glyphTop: glyph.top - message.bottom, glyphRoom: composer.top - glyph.bottom })}`,
          );
          await shot(page, `settled-${theme}-${width}`);
          // Docked in flow, the block gap the action row lies in; over a floating stack that band
          // (to the action row's bottom edge, restBand) and then the rest gap.
          expect(
            Math.abs(gap - (floating ? restBand(true) + REST_GAP : 24)),
            "composer gap after a message",
          ).toBeLessThanOrEqual(0.5);
          expect(Math.abs(glyph.top - message.bottom - 4), "action glyph top 4 under the message").toBeLessThanOrEqual(
            0.5,
          );
          expect(composer.top - glyph.bottom, "room under the action row").toBeGreaterThanOrEqual(3.5);
          expect(after, "showing the action row moves nothing").toEqual(message);
        } finally {
          await page.close();
        }
      });
      test(`${theme} ${width}px: the quiet row sits the foot gap under the composer box`, async () => {
        const page = await openScene("agent-pane.composer-row", "claude-auto", width, theme);
        try {
          await page.locator(".acpmux-composer-foot").waitFor();
          const box = await rectOf(page, ".acpmux-composer-box");
          const foot = await rectOf(page, ".acpmux-composer-foot");
          const mark = await rectOf(page, ".acpmux-composer-foot .acpmux-access-trigger svg");
          const gap = foot.top - box.bottom;
          const lead = (mark.left + mark.right) / 2 - box.left;
          console.log(`COMPOSER_FOOT ${JSON.stringify({ width, theme, gap, lead })}`);
          await shot(page, `foot-${theme}-${width}`);
          expect(Math.abs(gap - 4), "foot gap").toBeLessThanOrEqual(0.5);
          expect(Math.abs(lead - 22), "mode mark on the + glyph's centre").toBeLessThanOrEqual(0.5);
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
          const measured_ = await page.evaluate(() => {
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
            // Carets sit inline after their label (cmux#28018), so no `trail` line is measured here;
            // each sits at most one grid gap after its words.
            const caretGaps = {
              subsession:
                box(".cv-disclosure__line .cv-rotor").left - box(".cv-disclosure__line .cv-disclosure__label").right,
              group: box("[data-grid-count] .cv-tool__chevron").left - box("[data-grid-count] .cv-tool__text").right,
            };
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
              // One ordinary space: a count summary reads whole (ToolGroupRow.tsx `whole`), its verb
              // never in the verb column, so the space glyph is all that parts verb and count.
              if (document.querySelector(`${root} .cv-tool__verb`))
                throw new Error("A count summary's verb must not take the verb column");
              const label =
                document.querySelector(`${root} .cv-tool__summary, ${root} .cv-tool__text`)!.textContent ?? "";
              if (!/^\S+ \d+ \S/.test(label))
                throw new Error(`Count label must be "verb N noun": ${JSON.stringify(label)}`);
              if (
                getComputedStyle(document.querySelector(`${root} .cv-tool__text`)!).fontVariantNumeric !==
                "tabular-nums"
              )
                throw new Error("Counts must use tabular numerals");
            }
            return { result, caretGaps };
          });
          const { caretGaps } = measured_;
          const measured = measured_.result;
          console.log(`TRANSCRIPT_CARDS_CARETS ${JSON.stringify({ width, theme, caretGaps })}`);
          for (const [name, gap] of Object.entries(caretGaps)) {
            expect(gap, `${name} caret inline`).toBeGreaterThanOrEqual(-0.5);
            expect(gap, `${name} caret inline`).toBeLessThanOrEqual(8.5);
          }
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
                      : 0;
            expect(Math.abs(actual - expected), line).toBeLessThanOrEqual(0.5);
          }
        } finally {
          await page.close();
        }
      });
});
