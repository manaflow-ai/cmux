// Real transcript and Session Info components; all displayed content is synthetic.
import { afterAll, beforeAll, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser } from "playwright";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { warmViteServer } from "./support/warmDevServer";

await requireBrowserLane("transcript-glyph-alignment-browser.test.ts", async () => {
  setDefaultTimeout(120_000);
  const webviews = path.resolve(import.meta.dir, "..");
  const { createServer } = await import("vite");
  let vite: Awaited<ReturnType<typeof createServer>>;
  let browser: Browser;
  beforeAll(async () => {
    vite = await createServer({
      root: webviews,
      configFile: path.join(webviews, "vite.config.ts"),
      server: { port: 0, host: "127.0.0.1" },
      logLevel: "error",
    });
    await vite.listen();
    await warmViteServer(vite, "/test/browser/transcript-glyph-alignment.html");
    browser = await chromium.launch({ headless: true });
  });
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });
  for (const theme of ["dark", "light"] as const) {
    // Sign in again leads the failure card, and the footer row has no recovery action of its own. At
    // a narrow width every recovery action stays inside the row.
    test(`${theme}: narrow authentication failure keeps every recovery action inside the row`, async () => {
      const page = await browser.newPage({ viewport: { width: 320, height: 480 } });
      try {
        const port = (vite.httpServer!.address() as { port: number }).port;
        await page.goto(`http://127.0.0.1:${port}/test/browser/transcript-glyph-alignment.html?theme=${theme}&narrow`);
        await page.locator(".cv-turn-error__actions .cv-turn-auth-action").first().waitFor();
        await page.evaluate(() => document.fonts.ready);
        const recovery = await page.evaluate(() => {
          const row = document.querySelector("[data-auth-footer]")!.getBoundingClientRect();
          const measure = (selector: string) =>
            [...document.querySelectorAll(selector)].map((button) => {
              const box = button.getBoundingClientRect();
              return {
                left: box.left - row.left,
                right: box.right - row.right,
                width: box.width,
                whiteSpace: getComputedStyle(button).whiteSpace,
                primary: button.classList.contains("cv-turn-error__primary"),
              };
            });
          return {
            card: measure(".cv-turn-error__actions > .cv-turn-auth-action"),
            footer: measure(".cv-turn-actions .cv-turn-auth-action"),
          };
        });
        console.log(`AUTH_FAILURE_METRICS ${JSON.stringify({ theme, recovery })}`);
        // The card leads with its one filled button, Sign in again; the row offers none.
        expect(recovery.card.length).toBeGreaterThanOrEqual(1);
        expect(recovery.card.filter((button) => button.primary)).toHaveLength(1);
        expect(recovery.footer).toHaveLength(0);
        for (const button of recovery.card) {
          expect(button.width).toBeGreaterThan(0);
          expect(button.left).toBeGreaterThanOrEqual(0);
          expect(button.right).toBeLessThanOrEqual(0.5);
        }
      } finally {
        await page.close();
      }
    });
  }
  for (const theme of ["dark", "light"] as const)
    for (const height of [28, 40] as const) {
      test(`${theme} ${height}px: production glyphs share the text center line`, async () => {
        const page = await browser.newPage({
          viewport: { width: 760, height: 740 },
          deviceScaleFactor: 2,
        });
        try {
          const errors: string[] = [];
          page.on("pageerror", (error) => errors.push(error.message));
          const port = (vite.httpServer!.address() as { port: number }).port;
          await page.goto(
            `http://127.0.0.1:${port}/test/browser/transcript-glyph-alignment.html?theme=${theme}&height=${height}`,
          );
          await page.locator("[data-footer-row] .cv-user__time").waitFor();
          await page.evaluate(() => document.fonts.ready);
          const measurements = await page.evaluate(() => {
            const center = (el: Element) => {
              const r = el.getBoundingClientRect();
              return (r.top + r.bottom) / 2;
            };
            const measure = (scope: Element, label: string, glyphs: string) => {
              const text = scope.querySelector(label);
              if (!text) throw new Error(`Missing text: ${label}`);
              return [...scope.querySelectorAll(glyphs)].map((glyph) => {
                const r = glyph.getBoundingClientRect();
                return {
                  delta: Math.abs(center(glyph) - center(text)),
                  width: r.width,
                  height: r.height,
                };
              });
            };
            const rows = [...document.querySelectorAll<HTMLElement>("[data-glyph-row]")].map((scope) => {
              const kind = scope.dataset.glyphRow!;
              const selectors: Record<string, [string, string]> = {
                // A finished call draws no check and no time (Codex parity, 2026-11-11): its words and chevron.
                tool: [".cv-tool__text", "svg.cv-tool__chevron"],
                command: [".cv-command__text", "svg.cv-tool__chevron"],
                worked: [".cv-worked__label", ".cv-worked__chevron"],
                // A closed thought reads its words after the brain glyph (Codex parity).
                thought: [".cv-thought__preview", ".cv-tool__icon svg, .cv-tool__chevron"],
                "session-info": [
                  ".acpmux-session-info-section__title",
                  ".acpmux-session-info-section__icon, .acpmux-session-info-section__fold",
                ],
                read: ["[data-read-label]", ".cv-user__read svg"],
              };
              return { kind, glyphs: measure(scope, ...selectors[kind]!) };
            });
            const footer = measure(document.querySelector("[data-footer-row]")!, ".cv-user__time", ".cv-iconbtn svg");
            // The switcher's head slot is drawn only in other looks (VersionSwitcher.tsx, display none).
            const versionFooter = measure(
              document.querySelector("[data-version-footer-row]")!,
              ".cv-user__time",
              '.cv-iconbtn:not([data-version-slot="head"] .cv-iconbtn) svg',
            );
            // The last turn's Retry is its reply footer's (TurnFooter): no message row draws one.
            const retry = (kind: string) => document.querySelector(`[data-received-row="${kind}"] .cv-message-retry`);
            const sessionInfo = document.querySelector('[data-glyph-row="session-info"]')!;
            const sectionTitle = sessionInfo
              .querySelector(".acpmux-session-info-section__title")!
              .getBoundingClientRect();
            const environmentName = sessionInfo
              .querySelector(".acpmux-session-info-row__name")!
              .getBoundingClientRect();
            return {
              rows,
              footer,
              versionFooter,
              retryHidden: retry("nonretryable"),
              retryShown: retry("retryable"),
              sessionInfoColumnDelta: Math.abs(sectionTitle.left - environmentName.left),
            };
          });
          console.log(`GLYPH_METRICS ${JSON.stringify({ theme, height, ...measurements })}`);
          if (process.env.CMUX_GLYPH_CAPTURES === "1") {
            const png = await page.screenshot();
            console.log(
              `GLYPH_CAPTURE ${JSON.stringify({ name: `${theme}-${height}.png`, base64: png.toString("base64") })}`,
            );
          }
          expect(errors).toEqual([]);
          expect(measurements.rows).toHaveLength(7);
          expect(measurements.sessionInfoColumnDelta).toBeLessThanOrEqual(0.5);
          for (const row of measurements.rows) {
            expect(row.glyphs.length, row.kind).toBeGreaterThan(0);
            for (const glyph of row.glyphs) expect(glyph.delta, row.kind).toBeLessThanOrEqual(0.5);
          }
          // Retry and its model switch moved to the reply footer (TurnFooter), and Save as Prompt is
          // gone (Leo, 2026-11-24: "save prompt butotn still bad"): Copy, and the version switcher's two.
          expect(measurements.footer).toHaveLength(1);
          expect(measurements.versionFooter).toHaveLength(3);
          for (const glyph of [...measurements.footer, ...measurements.versionFooter]) {
            expect(glyph.delta, "sent footer").toBeLessThanOrEqual(0.5);
            expect(glyph.width, "footer glyph width").toBe(16);
            expect(glyph.height, "footer glyph height").toBe(16);
          }
          expect(measurements.retryHidden).toBeNull();
          expect(measurements.retryShown).toBeNull();
        } finally {
          await page.close();
        }
      });
      // Leo, 2026-11-17: "stop making the copy button move with the text ... why was it not just at
      // the right edge": a waiting prompt's buttons end at its bubble's right edge, as a sent
      // prompt's. Leo, 2026-11-24, on a waiting prompt drawn two ways (the queued row and a
      // "(clock) Sending" note): "this one is good. why were ther e2 of them". A prompt on its way
      // draws the queued row, with no clock note, at the same edge and height as the queued one.
      test(`${theme}: a prompt on its way draws the queued row with no clock, its buttons at the sent row's right edge`, async () => {
        const page = await browser.newPage({ viewport: { width: 760, height: 900 }, deviceScaleFactor: 2 });
        try {
          const port = (vite.httpServer!.address() as { port: number }).port;
          await page.goto(`http://127.0.0.1:${port}/test/browser/transcript-glyph-alignment.html?theme=${theme}`);
          await page.locator("[data-pending-row] .cv-user__send-now").waitFor();
          await page.evaluate(() => document.fonts.ready);
          const m = await page.evaluate(() => {
            const rowRight = (row: Element) =>
              row.querySelector(".cv-user__actions .cv-message-footer-row")!.getBoundingClientRect().right -
              row.querySelector(".cv-user__bubble")!.getBoundingClientRect().right;
            const look = (selector: string) => {
              const scope = document.querySelector(selector)!;
              const sendNow = scope.querySelector<HTMLElement>(".cv-user__send-now");
              return {
                right: rowRight(scope),
                height: scope.querySelector(".cv-user__actions .cv-message-footer-row")!.getBoundingClientRect().height,
                notes: scope.querySelectorAll(".cv-user__pending-state").length,
                state: sendNow?.dataset.pendingState,
                text: scope.textContent ?? "",
              };
            };
            return {
              pending: look("[data-pending-row]"),
              queued: look("[data-queued-row]"),
              sentRight: rowRight(document.querySelector("[data-sent-twin-row]")!),
            };
          });
          console.log(`PENDING_ROW ${JSON.stringify({ theme, ...m })}`);
          expect(m.pending.state).toBe("sending");
          expect(m.queued.state).toBe("queued");
          for (const look of [m.pending, m.queued]) {
            expect(look.notes).toBe(0);
            expect(look.text).not.toContain("Sending");
            expect(look.text).not.toContain("Queued, sends when");
            expect(Math.abs(look.right - m.sentRight)).toBeLessThanOrEqual(0.5);
          }
          expect(Math.abs(m.pending.height - m.queued.height)).toBeLessThanOrEqual(0.5);
        } finally {
          await page.close();
        }
      });
    }
});
