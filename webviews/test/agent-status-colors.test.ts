// Colored additions, deletions and status text follow the active terminal palette. The native
// AgentPaneTheme lifts ANSI slots to a readable floor over elevated glass; this test keeps that
// contract visible on the PR card, edit summaries and tool rows without touching the diff viewer.
import { readFileSync } from "node:fs";
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser } from "playwright";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("agent-status-colors.test.ts", async () => {
  setDefaultTimeout(60_000);
  try {
    await (await chromium.launch({ headless: true })).close();
  } catch {
    console.warn("agent-status-colors: skipping (run `bunx playwright install chromium`)");
    describe.skip("agent status colors", () => test("chromium", () => {}));
    return;
  }

  const src = path.resolve(import.meta.dir, "../src");
  const css = [
    "agent-session/shared/styles.css",
    "agent-session/acpmux/styles.css",
    "agent-session/acpmux/conversation/conversation.css",
    "agent-session/acpmux/chips/linkCard.css",
  ]
    .map((file) => readFileSync(path.join(src, file), "utf8"))
    .join("\n");
  let browser: Browser | undefined;
  beforeAll(async () => {
    browser = await chromium.launch({ headless: true });
  });
  afterAll(async () => {
    await browser?.close();
  });

  const themes = [
    {
      name: "light terminal",
      scheme: "light",
      background: "#ffffff",
      text: "#1f1f1f",
      palette: { green: "#1a7f37", red: "#b42318", yellow: "#8a5a00", purple: "#8250df" },
    },
    {
      name: "dark terminal",
      scheme: "dark",
      background: "#1e1e1e",
      text: "#f2f2f2",
      palette: { green: "#56d364", red: "#ff7b72", yellow: "#e3b341", purple: "#d2a8ff" },
    },
    {
      name: "colorful terminal",
      scheme: "dark",
      background: "#16121f",
      text: "#f7f0ff",
      palette: { green: "#52ffa8", red: "#ff6b9d", yellow: "#ffe66d", purple: "#c792ea" },
    },
  ] as const;

  for (const theme of themes) {
    test(`uses bright ANSI status colors on ${theme.name}`, async () => {
      const page = await browser!.newPage();
      const { green, red, yellow, purple } = theme.palette;
      await page.setContent(
        `<html style="color-scheme:${theme.scheme};--agent-text:${theme.text};--agent-page-bg:${theme.background};` +
          `--agent-ansi-10:${green};--agent-ansi-9:${red};--agent-ansi-11:${yellow};--agent-ansi-13:${purple};` +
          `--agent-success:#00ff00;--agent-danger:#00ff00;--agent-warning:#00ff00">` +
          `<style>${css}</style><body style="background:${theme.background}">` +
          `<span class="acpmux-pr-card__added">+1</span>` +
          `<span class="acpmux-pr-card__removed">−1</span>` +
          `<span class="cv-edit-diff__add">+1</span>` +
          `<span class="cv-edit-diff__del">−1</span>` +
          `<span class="cv-command__ok">✓</span>` +
          `<span class="cv-tool__failed">failed</span>` +
          `<span class="acpmux-pr-card__glyph" data-state="merged">merged</span>` +
          `</body></html>`,
      );
      const actual = await page.evaluate(() => {
        const color = (selector: string) => getComputedStyle(document.querySelector(selector)!).color;
        const canvas = document.createElement("canvas").getContext("2d", { willReadFrequently: true })!;
        const luminance = (value: string) => {
          canvas.fillStyle = value;
          canvas.fillRect(0, 0, 1, 1);
          const channels = Array.from(canvas.getImageData(0, 0, 1, 1).data.slice(0, 3)).map((channel) => {
            const normalized = channel / 255;
            return normalized <= 0.04045 ? normalized / 12.92 : ((normalized + 0.055) / 1.055) ** 2.4;
          });
          return 0.2126 * channels[0]! + 0.7152 * channels[1]! + 0.0722 * channels[2]!;
        };
        const colors = {
          add: color(".acpmux-pr-card__added"),
          remove: color(".acpmux-pr-card__removed"),
          editAdd: color(".cv-edit-diff__add"),
          editRemove: color(".cv-edit-diff__del"),
          success: color(".cv-command__ok"),
          failure: color(".cv-tool__failed"),
          merged: color(".acpmux-pr-card__glyph"),
        };
        const surface = luminance(getComputedStyle(document.body).backgroundColor);
        const ratio = (value: string) => {
          const ink = luminance(value);
          return (Math.max(ink, surface) + 0.05) / (Math.min(ink, surface) + 0.05);
        };
        return {
          colors,
          ratios: Object.fromEntries(Object.entries(colors).map(([key, value]) => [key, ratio(value)])),
        };
      });
      const rgb = (hex: string) => {
        const channels = [0, 2, 4].map((offset) => Number.parseInt(hex.slice(offset + 1, offset + 3), 16));
        return `rgb(${channels.join(", ")})`;
      };
      expect(actual.colors.add).toBe(rgb(green));
      expect(actual.colors.remove).toBe(rgb(red));
      expect(actual.colors.editAdd).toBe(actual.colors.success);
      expect(actual.colors.editRemove).toBe(actual.colors.failure);
      expect(actual.colors.merged).toBe(rgb(purple));
      expect(actual.colors.merged).not.toBe(actual.colors.failure);
      for (const ratio of Object.values(actual.ratios)) expect(ratio).toBeGreaterThanOrEqual(4.5);
      await page.close();
    });
  }
});
