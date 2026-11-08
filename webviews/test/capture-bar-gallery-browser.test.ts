// l10n-allow-file: browser fixture labels and diagnostics, not shipped UI.
// cmux-web-test-timeout: 300
//
// The capture bar (agent-pane.capture-bar, CaptureBar.gallery.ts) in real Chromium on the gallery frame,
// light and dark: every arm's bar fits the pane with nothing cut off, the recording line shows its time
// and Stop, and the play (shortcut, a Window screenshot into the composer, Record then Stop) lands two
// chips. Every state's still goes to $FAST_CHECKS_OUT for the PR. Leo, 2026-11-07: "could we also have
// a more native screenshot/screensharer (ergonomic one)/video recording of the app type thing/route?"
// CI fails the file when Chromium cannot launch (requireBrowserLane).
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser, type Page } from "playwright";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("capture-bar-gallery-browser.test.ts", async () => {
  setDefaultTimeout(240_000);
  const ENTRY = "agent-pane.capture-bar";
  const WIDTH = 720;
  const HEIGHT = 300;
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
    await warmGalleryFrame(vite, ENTRY, { browser, params: { variant: "band" } });
  });
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });

  async function open(variant: string, colorScheme: "light" | "dark", width = WIDTH): Promise<Page> {
    const page = await browser!.newPage({ viewport: { width, height: HEIGHT } });
    const base = `http://127.0.0.1:${(vite!.httpServer!.address() as { port: number }).port}`;
    await page.goto(base + galleryFrame(ENTRY, { variant, colorScheme, width, height: HEIGHT }));
    await page.waitForFunction(
      () => ["1", "error"].includes(document.documentElement.dataset.galleryReady ?? ""),
      undefined,
      { timeout: 90_000 },
    );
    expect(await page.evaluate(() => document.documentElement.dataset.galleryReady)).toBe("1");
    return page;
  }

  /// Every control of the bar inside the bar's box, and the bar inside the viewport.
  async function clipped(page: Page): Promise<string[]> {
    await page.locator(".acpmux-capture__body").waitFor();
    // The height eases on open: read once it settles.
    await page.waitForFunction(() => {
      const bar = document.querySelector<HTMLElement>(".acpmux-capture");
      return !!bar && bar.getAnimations().every((animation) => animation.playState !== "running");
    });
    return page.evaluate(() => {
      const body = document.querySelector(".acpmux-capture")!.getBoundingClientRect();
      const room = document.querySelector(".acpmux-capture__room")!.getBoundingClientRect();
      const problems: string[] = [];
      if (Math.abs(body.height - room.height) > 0.5)
        problems.push(`bar ${body.height} tall, its content ${room.height}`);
      if (body.right > window.innerWidth + 0.5) problems.push(`bar past the viewport (${body.right})`);
      // The composer card under the bar keeps the height its content needs, inside the pane.
      const card = document.querySelector<HTMLElement>("[data-stage-composer]")!;
      const cardBox = card.getBoundingClientRect();
      if (cardBox.bottom > window.innerHeight + 0.5) problems.push(`composer past the pane (${cardBox.bottom})`);
      if (card.scrollHeight > card.clientHeight + 0.5)
        problems.push(`composer squeezed to ${card.clientHeight} under ${card.scrollHeight}`);
      // No two controls overlap (a row that cannot wrap pushes them into each other).
      const controls = [...document.querySelectorAll<HTMLElement>(".acpmux-capture button, .acpmux-capture label")];
      const boxes = controls.map((control) => control.getBoundingClientRect());
      for (let a = 0; a < boxes.length; a++)
        for (let b = a + 1; b < boxes.length; b++) {
          const [p, q] = [boxes[a], boxes[b]];
          const overlap =
            Math.min(p.right, q.right) - Math.max(p.left, q.left) > 0.5 &&
            Math.min(p.bottom, q.bottom) - Math.max(p.top, q.top) > 0.5;
          if (overlap && !controls[a].contains(controls[b]) && !controls[b].contains(controls[a]))
            problems.push(`${controls[a].textContent} overlaps ${controls[b].textContent}`);
        }
      for (const control of document.querySelectorAll<HTMLElement>(".acpmux-capture button, .acpmux-capture label")) {
        const box = control.getBoundingClientRect();
        if (box.bottom > body.bottom + 0.5 || box.right > body.right + 0.5 || box.top < body.top - 0.5)
          problems.push(
            `${control.className || control.tagName}: ${control.textContent} cut off (${box.top}-${box.bottom} in ${body.top}-${body.bottom})`,
          );
      }
      return problems;
    });
  }

  describe("capture bar arms", () => {
    for (const variant of ["band", "segmented", "chip", "recording"])
      for (const scheme of ["light", "dark"] as const)
        test(`${variant} in ${scheme}`, async () => {
          const page = await open(variant, scheme);
          try {
            const problems = await clipped(page);
            if (out) await page.screenshot({ path: path.join(out, `capture-bar-${variant}-${scheme}.png`) });
            expect(problems).toEqual([]);
            if (variant === "band") {
              // At a usual pane width the band is one row: its × never wraps alone onto a second line.
              const rows = await page.evaluate(
                () =>
                  new Set(
                    Array.from(document.querySelectorAll(".acpmux-capture button"), (button) =>
                      Math.round(button.getBoundingClientRect().top / 8),
                    ),
                  ).size,
              );
              expect(rows).toBe(1);
            }
            if (variant === "recording") {
              expect(await page.locator(".acpmux-capture__elapsed").textContent()).toMatch(/^0:1\d$/);
              await page.locator(".acpmux-capture__stop").waitFor();
            }
            if (out) await page.screenshot({ path: path.join(out, `capture-bar-${variant}-${scheme}.png`) });
          } finally {
            await page.close();
          }
        });

    for (const variant of ["segmented", "chip"])
      test(`the ${variant} arm wraps in a narrow pane, nothing cut off or overlapping`, async () => {
        const page = await open(variant, "dark", 360);
        try {
          const problems = await clipped(page);
          if (out) await page.screenshot({ path: path.join(out, `capture-bar-${variant}-narrow-dark.png`) });
          expect(problems).toEqual([]);
        } finally {
          await page.close();
        }
      });

    test("the band wraps in a narrow pane, nothing cut off", async () => {
      const page = await open("band", "dark", 420);
      try {
        const problems = await clipped(page);
        if (out) await page.screenshot({ path: path.join(out, "capture-bar-band-narrow-dark.png") });
        expect(problems).toEqual([]);
        if (out) await page.screenshot({ path: path.join(out, "capture-bar-band-narrow-dark.png") });
      } finally {
        await page.close();
      }
    });

    test("play: the shortcut, a Window screenshot, then Record and Stop land two chips", async () => {
      const page = await open("play", "dark");
      try {
        await page.waitForFunction(() => document.querySelectorAll("[data-stage-chip]").length === 2, undefined, {
          timeout: 60_000,
        });
        expect(await page.locator("[data-stage-phase]").textContent()).toBe("closed");
        if (out) await page.screenshot({ path: path.join(out, "capture-bar-play-dark.png") });
      } finally {
        await page.close();
      }
    });
  });
});
