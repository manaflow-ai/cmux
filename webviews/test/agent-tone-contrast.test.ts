// Each subagent's name, drawn in its color (subagents.css `--agent-tone-ink`), reads at WCAG AA
// (4.5:1) on the light theme's background, with the stylesheet's fallback tones and with a stock
// light terminal palette, whose yellow and cyan are the faintest.
//
// Real Chromium from Playwright; CI fails the file when it cannot launch (requireBrowserLane).
import { readFileSync } from "node:fs";
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser } from "playwright";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("agent-tone-contrast.test.ts", async () => {
  setDefaultTimeout(60_000);
  try {
    await (await chromium.launch({ headless: true })).close();
  } catch {
    console.warn("agent-tone-contrast: skipping (run `bunx playwright install chromium`)");
    describe.skip("agent tone contrast", () => test("chromium", () => {}));
    return;
  }
  const css = readFileSync(
    path.resolve(import.meta.dir, "../src/agent-session/acpmux/subagents/subagents.css"),
    "utf8",
  );
  // Apple Terminal's Basic (light) palette: green, magenta, yellow, cyan and bright magenta.
  const terminal =
    "--agent-ansi-2:#00a600;--agent-ansi-5:#b200b2;--agent-ansi-3:#999900;--agent-ansi-6:#00a6b2;--agent-ansi-13:#e500e5;";
  let browser: Browser | undefined;
  beforeAll(async () => {
    browser = await chromium.launch({ headless: true });
  });
  afterAll(async () => {
    await browser?.close();
  });

  /** Each tone's name color against white, as a contrast ratio. */
  async function ratios(palette: string): Promise<number[]> {
    const page = await browser!.newPage();
    const names = Array.from(
      { length: 5 },
      (_, tone) => `<div class="cv-subagent" data-agent-tone="${tone}"><span class="cv-subagent__name">n</span></div>`,
    ).join("");
    await page.setContent(
      `<html data-theme="light" style="--agent-text:#1d1d1f;${palette}"><style>${css}</style><body style="background:#fff">${names}</body></html>`,
    );
    const out = await page.evaluate(() => {
      const canvas = document.createElement("canvas").getContext("2d", { willReadFrequently: true })!;
      const luminance = (color: string) => {
        canvas.clearRect(0, 0, 1, 1);
        canvas.fillStyle = color;
        canvas.fillRect(0, 0, 1, 1);
        const rgb = Array.from(canvas.getImageData(0, 0, 1, 1).data.slice(0, 3)).map((v) => {
          const c = v / 255;
          return c <= 0.04045 ? c / 12.92 : ((c + 0.055) / 1.055) ** 2.4;
        });
        return 0.2126 * rgb[0]! + 0.7152 * rgb[1]! + 0.0722 * rgb[2]!;
      };
      return [...document.querySelectorAll(".cv-subagent__name")].map(
        (name) => 1.05 / (luminance(getComputedStyle(name).color) + 0.05),
      );
    });
    await page.close();
    return out;
  }

  test("the fallback tones read at AA on light", async () => {
    for (const ratio of await ratios("")) expect(ratio).toBeGreaterThanOrEqual(4.5);
  });

  test("a light terminal palette's tones read at AA on light", async () => {
    for (const ratio of await ratios(terminal)) expect(ratio).toBeGreaterThanOrEqual(4.5);
  });
});
