// l10n-allow-file: asserts the English labels and fixture rules the gallery renders, not shipped UI.
// The permission card's answers (PermissionCard.tsx). Leo 2026-10-25, on a Claude Code ffmpeg ask:
// "the allow button, like this, it shouldn't be encompassing so much. Like I'm pretty sure we can
// have, like, this be, I mean, just always allow. But then this other, like, thing shouldn't be the
// same thing." Always allow held the whole session rule as a full-width row, and the rule showed a
// second time under the buttons. Real gallery frames (agent-pane.permission-card), at the width of
// Leo's pane and a narrow one:
//   - every answer the harness offers is a compact button in one row, all the same height, none
//     holding the rule;
//   - the rule (and a Codex ask's folder) shows once, as one muted line under the buttons, cut to
//     one line with the whole text in its tooltip.
//
// Real Chromium from Playwright; CI fails the file when it cannot launch (requireBrowserLane).
import { afterAll, beforeAll, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser } from "playwright";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("agent-pane-permission-card-row.test.ts", async () => {
  setDefaultTimeout(240_000);
  const webviews = path.resolve(import.meta.dir, "..");
  const { createServer } = await import("vite");
  let vite: Awaited<ReturnType<typeof createServer>> | undefined;
  let browser: Browser | undefined;
  const ENTRY = "agent-pane.permission-card";

  beforeAll(async () => {
    vite = await createServer({
      configFile: path.join(webviews, "vite.config.gallery-dev.ts"),
      server: { port: 0, host: "127.0.0.1", strictPort: false },
      logLevel: "error",
    });
    await vite.listen();
    browser = await chromium.launch({ headless: true });
    await warmGalleryFrame(vite, ENTRY, { browser, params: { variant: "claude-long-rule" } });
  });
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });

  async function measure(variant: string, width: number) {
    const port = (vite!.httpServer!.address() as { port: number }).port;
    const page = await browser!.newPage({ viewport: { width, height: 460 } });
    await page.goto(`http://127.0.0.1:${port}${galleryFrame(ENTRY, { variant })}`);
    await page.locator(".acpmux-permission-ask .acpmux-permission-buttons").first().waitFor({ timeout: 90_000 });
    await page.waitForFunction(() => document.documentElement.dataset.galleryReady === "1", undefined, {
      timeout: 30_000,
    });
    const found = await page.evaluate(() => {
      const card = document.querySelector<HTMLElement>(".acpmux-permission-ask")!;
      const row = card.querySelector<HTMLElement>(".acpmux-permission-buttons")!;
      const buttons = [...card.querySelectorAll<HTMLElement>("button")].filter(
        (button) => !button.classList.contains("acpmux-permission-command-toggle"),
      );
      const scope = card.querySelector<HTMLElement>(".acpmux-permission-scope");
      return {
        cardWidth: card.getBoundingClientRect().width,
        outside: buttons.filter((button) => !row.contains(button)).map((button) => button.textContent),
        buttons: buttons.map((button) => {
          const rect = button.getBoundingClientRect();
          return { label: button.getAttribute("aria-label"), text: button.textContent ?? "", top: rect.top, height: rect.height, width: rect.width };
        }),
        scope: scope && {
          text: scope.textContent ?? "",
          title: scope.title,
          height: scope.getBoundingClientRect().height,
          lineHeight: parseFloat(getComputedStyle(scope).lineHeight),
          belowRow: scope.getBoundingClientRect().top >= row.getBoundingClientRect().bottom,
        },
        cardText: card.innerText,
      };
    });
    await page.close();
    return found;
  }

  const RULE =
    'Allow //Users/you/scratch/whats-new-video/reel/**, rm f/*, ffmpeg -v error -i reel.mp4 -vf "fps=1,scale=640:-1,tile=4x4" -frames:v 1 sheet.jpg for this session';

  test("Leo's ffmpeg ask: three compact answers in one row, the rule once under them", async () => {
    for (const width of [1060, 820]) {
      const card = await measure("claude-long-rule", width);
      expect(card.outside).toEqual([]);
      expect(card.buttons.map((button) => button.label)).toEqual(["Allow once", "Always allow", "Deny"]);
      // One row, one height, and no answer stretched across the card.
      expect(new Set(card.buttons.map((button) => Math.round(button.top))).size).toBe(1);
      expect(new Set(card.buttons.map((button) => Math.round(button.height))).size).toBe(1);
      for (const button of card.buttons) {
        expect(button.width).toBeLessThan(card.cardWidth / 3);
        expect(button.text).not.toContain("ffmpeg");
      }
      // The rule: once, one muted line under the buttons, the whole of it on hover.
      expect(card.cardText.split("rm f/*, ffmpeg").length - 1).toBe(1);
      expect(card.scope?.belowRow).toBe(true);
      expect(card.scope?.title).toBe(RULE);
      expect(card.scope!.height).toBeLessThanOrEqual(card.scope!.lineHeight + 1);
    }
  });

  test("a Codex ask with five answers keeps them all in the row and its scope on one line", async () => {
    const card = await measure("codex-five-options", 1060);
    expect(card.outside).toEqual([]);
    expect(card.buttons.map((button) => button.label)).toEqual([
      "Allow once",
      "Always allow",
      "Deny",
      "No, continue without running it",
      "Show me the plan first",
    ]);
    expect(new Set(card.buttons.map((button) => Math.round(button.top))).size).toBe(1);
    expect(new Set(card.buttons.map((button) => Math.round(button.height))).size).toBe(1);
    for (const button of card.buttons) expect(button.text).not.toContain("git push");
    expect(card.cardText.split("start with `git push`").length - 1).toBe(1);
    expect(card.scope?.title).toContain("In /Users/you/src/atlas-web");
    expect(card.scope!.height).toBeLessThanOrEqual(card.scope!.lineHeight + 1);
  });

  test("a narrow pane wraps the answers rather than cutting them, and keeps the scope on one line", async () => {
    const card = await measure("codex-five-options", 420);
    expect(card.outside).toEqual([]);
    expect(new Set(card.buttons.map((button) => Math.round(button.height))).size).toBe(1);
    for (const button of card.buttons) expect(button.width).toBeLessThanOrEqual(card.cardWidth);
    expect(card.scope!.height).toBeLessThanOrEqual(card.scope!.lineHeight + 1);
  });
});
