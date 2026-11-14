// cmux-web-test-timeout: 240
// The Cloud composer strip at narrow widths: the Environment chip gives way first, to its icon alone
// (its full name in its tooltip and accessible name), before the Folder, the Where chip or the team
// tag cut. Coordinator's decision for cmux#39001, on Leo's authority: "at narrow composer widths, the
// Environment chip collapses to its icon first, with its label moving into its tooltip, before
// anything else gives way. Nothing changes at full width." Measured in real Chromium on the gallery
// entry agent-pane.cloud-composer-chips.
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser, type Page } from "playwright";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { warmViteServer } from "./support/warmDevServer";

await requireBrowserLane("cloud-composer-chips-narrow.test.ts", async () => {
  setDefaultTimeout(180_000);
  try {
    await (await chromium.launch({ headless: true })).close();
  } catch {
    console.warn("cloud-composer-chips-narrow: skipping (run `bunx playwright install chromium`)");
    describe.skip("cloud composer chips narrow", () => test("chromium", () => {}));
    return;
  }
  const webviews = path.resolve(import.meta.dir, "..");
  const { createServer } = await import("vite");
  let vite: Awaited<ReturnType<typeof createServer>> | undefined;
  let browser: Browser | undefined;
  const ENTRY = "agent-pane.cloud-composer-chips";
  const ENTRY_PATH = "src/agent-session/acpmux/cloudComposerChips.gallery.ts";
  const stageURL = (variant: string) =>
    `http://127.0.0.1:${(vite!.httpServer!.address() as { port: number }).port}/gallery/frame.html?entry=${ENTRY}&entryPath=${ENTRY_PATH}&variant=${variant}`;

  beforeAll(async () => {
    vite = await createServer({
      configFile: path.join(webviews, "vite.config.gallery-dev.ts"),
      server: { port: 0, host: "127.0.0.1", strictPort: false },
      logLevel: "error",
    });
    await vite.listen();
    for (const file of [ENTRY_PATH, "src/gallery/frame/component.tsx"])
      if ((await warmViteServer(vite, `/gallery/${file}`)) === 0)
        throw new Error(`warmViteServer: ${file} imports nothing; is it served?`);
    browser = await chromium.launch({ headless: true });
    // The first load can run Vite's dependency optimizer and reload mid-compile.
    const warm = await browser.newPage({ viewport: { width: 760, height: 420 } });
    await warm.goto(stageURL("personal-default"));
    for (;;) {
      try {
        await warm.waitForFunction(() => document.documentElement.dataset.galleryReady, undefined, { timeout: 0 });
        break;
      } catch (error) {
        if (!/context was destroyed|navigat/i.test(String(error))) throw error;
      }
    }
    await warm.close();
  });
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });

  type Chip = { kind: string; width: number; labelShown: boolean; cut: boolean; name: string; tooltip: string };
  type Strip = {
    strip: number;
    viewport: number;
    chips: Chip[];
    play: string | undefined;
    error: string | undefined;
  };

  /// The variant's stage at `width`, its play done and the Environment chip's column settled.
  const open = async (variant: string, width: number): Promise<{ page: Page; strip: Strip }> => {
    const page = await browser!.newPage({ viewport: { width, height: 420 } });
    await page.goto(stageURL(variant));
    await page.waitForFunction(() => document.documentElement.dataset.galleryReady === "1");
    await page.evaluate(() => document.fonts.ready);
    await page.waitForFunction(() => {
      const slot = document.querySelector('.acpmux-cloud-env-slot[data-shown="true"]');
      const chip = slot?.querySelector(".acpmux-cloud-env");
      return (
        !!slot &&
        !!chip &&
        getComputedStyle(slot).opacity === "1" &&
        slot.getBoundingClientRect().width >= chip.scrollWidth - 0.5
      );
    });
    const strip = await page.evaluate(() => {
      const shown = (element: Element | null) =>
        !!element && element.getBoundingClientRect().width > 0 && getComputedStyle(element).display !== "none";
      const pickers = [...document.querySelectorAll(".acpmux-composer-context .acpmux-location-picker")].filter(shown);
      const chips = pickers.map((picker) => {
        const button = picker.querySelector(".acpmux-location-button, .acpmux-location-readonly");
        const parts = [
          ...picker.querySelectorAll(
            ".acpmux-location-label, .acpmux-location-head, .acpmux-location-tail, .acpmux-team-tag-name",
          ),
        ].filter(shown);
        return {
          kind: picker.getAttribute("data-kind") ?? picker.getAttribute("data-rows") ?? "folder",
          width: picker.getBoundingClientRect().width,
          labelShown: shown(picker.querySelector(".acpmux-location-label")),
          cut: parts.some(
            (part) => part.scrollWidth > part.clientWidth + 1 || (part.textContent ?? "").trim().endsWith("…"),
          ),
          name: button?.getAttribute("aria-label") ?? "",
          tooltip: picker.getAttribute("data-tooltip") ?? picker.getAttribute("title") ?? "",
        };
      });
      const report = (window as Window & { cmuxGalleryPlayReport?: { status: string; error?: string } })
        .cmuxGalleryPlayReport;
      const viewport = window.innerWidth;
      return {
        strip: document.querySelector(".acpmux-composer-strip")!.getBoundingClientRect().width,
        chips,
        viewport,
        play: report?.status,
        error: report?.error,
      };
    });
    // One short line per stage (lane-gh ci cuts long lines): the strip's width and each chip's.
    console.log(
      `ccc ${variant} @${width}: viewport ${strip.viewport} strip ${Math.round(strip.strip)} play ${strip.play} | ${strip.chips
        .map(
          (chip) => `${chip.kind} ${Math.round(chip.width)}${chip.labelShown ? "" : " icon"}${chip.cut ? " CUT" : ""}`,
        )
        .join(", ")}`,
    );
    return { page, strip };
  };

  const environment = (strip: Strip) => strip.chips.find((chip) => chip.kind === "cloud-environment")!;

  // The width variants (`<state>-full|760|400`) leave the pane at their width; the stage opens at it,
  // so their plays never resize and what is measured is the strip as it rests there.
  for (const state of ["personal-default", "team-bypass", "removed-team"]) {
    for (const [label, width] of [
      ["full", 1100],
      ["760", 760],
    ] as const)
      test(`${state} at ${width} px: every chip shows whole, the Environment chip with its name`, async () => {
        const { page, strip } = await open(`${state}-${label}`, width);
        try {
          expect(strip.error).toBeUndefined();
          expect(strip.chips.filter((chip) => chip.cut)).toEqual([]);
          expect(environment(strip).labelShown).toBe(true);
        } finally {
          await page.close();
        }
      });

    test(`${state} at 400 px: the Environment chip is its icon alone, named in its tooltip, and nothing else cuts`, async () => {
      const { page, strip } = await open(`${state}-400`, 400);
      try {
        expect(strip.error).toBeUndefined();
        expect(strip.chips.filter((chip) => chip.cut)).toEqual([]);
        const chip = environment(strip);
        expect(chip.labelShown).toBe(false);
        expect(chip.name).toMatch(/environment: auto/i);
        expect(chip.tooltip).toMatch(/environment: auto/i);
        // The other chips keep their names: the Environment chip gave way first.
        for (const other of strip.chips.filter((each) => each !== chip)) expect(other.labelShown).toBe(true);
      } finally {
        await page.close();
      }
    });
  }
});
