// l10n-allow-file: browser fixture labels and diagnostics, not shipped UI.
// cmux-web-test-timeout: 300
//
// The tagged-ask card (agent-pane.next-step-card, NextStepCard.tsx) in real Chromium on the gallery
// frame, light and dark: every look draws its question and one button per answer, the shipped box's
// buttons sit on one line at the normal width with the first carrying its ⌘↩ keycap, nothing draws
// past the frame's right edge, and an answered card has no buttons. With FAST_CHECKS_OUT set, each
// state's card is saved there at 2x for the PR. CI fails the file when Chromium cannot launch.
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser } from "playwright";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("next-step-card-gallery-browser.test.ts", async () => {
  setDefaultTimeout(240_000);
  const ENTRY = "agent-pane.next-step-card";
  const PANE_ENTRY = "agent-pane.next-step-in-pane";
  const HEIGHT = 280;
  const WIDTH = 640;
  const VARIANTS: Record<string, { buttons: number }> = {
    "box-choices": { buttons: 3 },
    "box-yes-no": { buttons: 2 },
    "box-answered": { buttons: 0 },
    "box-answered-typed": { buttons: 0 },
    "recap-choices": { buttons: 3 },
    "inline-choices": { buttons: 3 },
    "consent-choices": { buttons: 3 },
    "list-choices": { buttons: 3 },
  };
  const out = process.env.FAST_CHECKS_OUT;
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
    browser = await chromium.launch({ headless: true });
    await warmGalleryFrame(vite, ENTRY, { browser, params: { variant: "box-choices" } });
  });
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });

  describe("tagged-ask card looks", () => {
    for (const [variant, { buttons }] of Object.entries(VARIANTS))
      for (const scheme of ["dark", "light"] as const)
        test(`${variant} (${scheme})`, async () => {
          const page = await browser!.newPage({ viewport: { width: WIDTH, height: HEIGHT }, deviceScaleFactor: 2 });
          const errors: string[] = [];
          page.on("pageerror", (error) => errors.push(error.message));
          try {
            const base = `http://127.0.0.1:${(vite!.httpServer!.address() as { port: number }).port}`;
            await page.goto(base + galleryFrame(ENTRY, { variant, width: WIDTH, height: HEIGHT, colorScheme: scheme }));
            await page.waitForFunction(
              () => ["1", "error"].includes(document.documentElement.dataset.galleryReady ?? ""),
              undefined,
              { timeout: 90_000 },
            );
            expect(await page.evaluate(() => document.documentElement.dataset.galleryReady)).toBe("1");
            const card = page.locator(".acpmux-next-step").first();
            await card.waitFor();
            const layout = await page.evaluate(() => {
              const card = document.querySelector(".acpmux-next-step")!;
              const answers = [...card.querySelectorAll(".acpmux-next-step__answer")].map((el) =>
                el.getBoundingClientRect(),
              );
              return {
                text: card.textContent ?? "",
                buttons: answers.length,
                lines: new Set(answers.map((box) => Math.round(box.top))).size,
                keycap: card.querySelector(".acpmux-next-step__answer.is-primary .acpmux-keycap") !== null,
                right: card.getBoundingClientRect().right,
                width: document.documentElement.clientWidth,
              };
            });
            expect(layout.buttons).toBe(buttons);
            expect(layout.text).toMatch(/\?/);
            expect(layout.right).toBeLessThanOrEqual(layout.width);
            if (buttons > 0) expect(layout.keycap).toBe(true);
            if (variant.startsWith("box-") && buttons > 0) expect(layout.lines).toBe(1);
            if (out)
              await page
                .locator(".acpmux-next-step-gallery")
                .screenshot({ path: path.join(out, `${variant}-${scheme}.png`) });
            expect(errors).toEqual([]);
          } finally {
            await page.close();
          }
        });
  });

  // The real pane on a snapshot: the transcript's own shaping places the card (turns.ts NEXT_STEP).
  describe("in the agent pane", () => {
    for (const [variant, cards] of [
      ["waiting", 1],
      ["answered", 1],
      ["ordinary-question", 0],
    ] as const)
      for (const scheme of ["dark", "light"] as const)
        test(`${variant} (${scheme})`, async () => {
          const page = await browser!.newPage({ viewport: { width: 760, height: 560 }, deviceScaleFactor: 2 });
          try {
            const base = `http://127.0.0.1:${(vite!.httpServer!.address() as { port: number }).port}`;
            await page.goto(base + galleryFrame(PANE_ENTRY, { variant, width: 760, height: 560, colorScheme: scheme }));
            await page.waitForFunction(
              () => ["1", "error"].includes(document.documentElement.dataset.galleryReady ?? ""),
              undefined,
              { timeout: 90_000 },
            );
            expect(await page.evaluate(() => document.documentElement.dataset.galleryReady)).toBe("1");
            if (cards) await page.locator(".acpmux-next-step").first().waitFor();
            expect(await page.locator(".acpmux-next-step").count()).toBe(cards);
            if (variant === "answered") expect(await page.locator(".acpmux-next-step__answer").count()).toBe(0);
            if (out) await page.screenshot({ path: path.join(out, `pane-${variant}-${scheme}.png`) });
          } finally {
            await page.close();
          }
        });
  });

  // The click path, headless: the box from a real chat's call_log (a wrap-up called from a
  // cmux_exec script), a click on an answer, and that answer sent as the next prompt.
  test("a wrap-up answer click sends the answer as the next prompt", async () => {
    const page = await browser!.newPage({ viewport: { width: 760, height: 560 }, deviceScaleFactor: 2 });
    try {
      const base = `http://127.0.0.1:${(vite!.httpServer!.address() as { port: number }).port}`;
      await page.goto(
        base + galleryFrame(PANE_ENTRY, { variant: "wrap-up-click", width: 760, height: 560, colorScheme: "dark" }),
      );
      await page.waitForFunction(() => document.documentElement.dataset.galleryReady === "1", undefined, {
        timeout: 90_000,
      });
      const card = page.locator(".acpmux-next-step").first();
      await card.waitFor({ timeout: 20_000 }).catch(async (error: unknown) => {
        const seen = await page.evaluate(() => ({
          attach: (window as unknown as { cmuxGalleryLog: { method: string; params?: unknown }[] }).cmuxGalleryLog
            .filter((entry) => entry.method.includes("attach") || entry.method.includes("session/load"))
            .map((entry) => JSON.stringify(entry.params)),
          text: document.body.innerText.slice(0, 1200),
        }));
        throw new Error(`no next-step box; attach ${seen.attach.join(" | ")}; page: ${seen.text}`, { cause: error });
      });
      expect(await card.textContent()).toContain("Checked the folder: it is empty.");
      expect(await card.locator(".acpmux-next-step__answer").allTextContents()).toEqual([
        expect.stringContaining("Yes, add README"),
        "No thanks",
      ]);
      if (out) await page.screenshot({ path: path.join(out, "pane-wrap-up-code-mode-dark.png") });
      await card.locator(".acpmux-next-step__answer", { hasText: "Yes, add README" }).click();
      // The pane's send path on its acpmux link: the in-page mock logs each request it answers.
      const sent = await page
        .waitForFunction(
          () => {
            type Entry = { method: string; params?: { prompt?: unknown } };
            const log = (window as unknown as { cmuxGalleryLog: Entry[] }).cmuxGalleryLog;
            for (const entry of log) {
              if (entry.method === "acpmux session/prompt" && Array.isArray(entry.params?.prompt))
                return (entry.params.prompt as { text?: string }[]).map((block) => block.text ?? "").join("");
            }
            return undefined;
          },
          undefined,
          { timeout: 30_000 },
        )
        .catch(async (error: unknown) => {
          const calls = await page.evaluate(() =>
            (window as unknown as { cmuxGalleryLog: { method: string }[] }).cmuxGalleryLog.map((entry) => entry.method),
          );
          throw new Error(`no prompt was sent; the frame's calls: ${calls.join(", ")}`, { cause: error });
        });
      expect(await sent.jsonValue()).toBe("Yes, add README");
    } finally {
      await page.close();
    }
  });
});
