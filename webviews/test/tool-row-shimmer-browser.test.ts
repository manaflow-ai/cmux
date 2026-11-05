// A running tool row shows that it runs on its own words (Leo, 2026-11-03, on a running "Monitor"
// row whose spinner sat at the transcript's far edge: "this is kinda weird looking" / "doesn't
// claude desktop have the thinking shimmer go across stuff"): no mark is parked at the row's far
// edge, a light band crosses its words while it runs, a finished row has none, and Reduce Motion
// or the app's motion gate keep the dimmed words still. All displayed content is synthetic.
import { afterAll, beforeAll, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser } from "playwright";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { warmViteServer } from "./support/warmDevServer";

type Row = {
  id: string;
  state: string;
  text: string;
  /** Painted marks (svg) right of the words, other than the disclosure chevron. */
  detachedMarks: number;
  spinners: number;
  shimmer: boolean;
  bandAnimation: string;
  litText: string;
  litOverflow: string;
  animations: number;
  color: string;
  wordsGrew: boolean;
};

await requireBrowserLane("tool-row-shimmer-browser.test.ts", async () => {
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
    await warmViteServer(vite, "/test/browser/tool-row-shimmer.html");
    browser = await chromium.launch({ headless: true });
  });
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });

  async function measure(reducedMotion: "reduce" | "no-preference", motion?: string): Promise<Row[]> {
    const page = await browser.newPage({ viewport: { width: 820, height: 400 }, deviceScaleFactor: 2, reducedMotion });
    try {
      const errors: string[] = [];
      page.on("pageerror", (error) => errors.push(error.message));
      const port = (vite.httpServer!.address() as { port: number }).port;
      await page.goto(
        `http://127.0.0.1:${port}/test/browser/tool-row-shimmer.html${motion ? `?motion=${motion}` : ""}`,
      );
      await page.locator("[data-fixture-state] .cv-tool").nth(4).waitFor();
      await page.evaluate(() => document.fonts.ready);
      const rows = await page.evaluate(() =>
        [...document.querySelectorAll<HTMLElement>("[data-fixture-state]")].map((holder) => {
          const row = holder.querySelector<HTMLElement>(".cv-tool")!;
          const words = row.querySelector<HTMLElement>(".cv-tool__text, .cv-command__text")!;
          const wordsRight = words.getBoundingClientRect().right;
          const detachedMarks = [...row.querySelectorAll<SVGElement>("svg")].filter((svg) => {
            if (svg.closest(".cv-tool__chevron")) return false;
            const box = svg.getBoundingClientRect();
            const style = getComputedStyle(svg);
            return box.width > 0 && style.visibility !== "hidden" && style.opacity !== "0" && box.left >= wordsRight;
          }).length;
          const shimmer = words.querySelector<HTMLElement>(":scope > .cv-row-shimmer");
          const band = shimmer?.querySelector<HTMLElement>(".cv-row-shimmer__band");
          const lit = shimmer?.querySelector<HTMLElement>(".cv-row-shimmer__lit");
          const base = [...words.childNodes]
            .filter((node) => !(node instanceof HTMLElement && node.classList.contains("cv-row-shimmer")))
            .map((node) => node.textContent)
            .join("");
          return {
            id: row.dataset.toolId!,
            state: holder.dataset.fixtureState!,
            text: base,
            detachedMarks,
            spinners: row.querySelectorAll(".cv-spinner").length,
            shimmer: Boolean(shimmer && getComputedStyle(shimmer).display !== "none"),
            bandAnimation: band ? getComputedStyle(band).animationName : "none",
            litText: lit?.textContent ?? "",
            litOverflow: lit ? getComputedStyle(lit).textOverflow : "",
            animations: row.getAnimations({ subtree: true }).length,
            color: getComputedStyle(words).color,
            wordsGrew: words.scrollWidth > words.clientWidth + 0.5,
          };
        }),
      );
      expect(errors).toEqual([]);
      return rows;
    } finally {
      await page.close();
    }
  }

  test("a running row's words shimmer and no mark waits at its far edge; a finished row has none", async () => {
    const rows = await measure("no-preference");
    console.log(`TOOL_ROW_SHIMMER motion ${JSON.stringify(rows)}`);
    expect(rows.map((row) => row.id)).toEqual(["monitor", "read", "command", "done-read", "done-command"]);
    for (const row of rows) {
      expect(row.spinners, `spinner: ${row.id}`).toBe(0);
      expect(row.detachedMarks, `mark at the far edge: ${row.id}`).toBe(0);
      if (row.state === "running") {
        expect(row.shimmer, `shimmer: ${row.id}`).toBe(true);
        expect(row.bandAnimation, `band: ${row.id}`).toBe("cmux-shimmer-band");
        // The band lights the row's own words.
        expect(row.litText, `lit words: ${row.id}`).toBe(row.text);
        // A cut label ends in its ellipsis under the band too.
        expect(row.litOverflow, `lit ellipsis: ${row.id}`).toBe("ellipsis");
        expect(row.animations, `loops: ${row.id}`).toBe(2);
        // The moving band never makes the words read as cut (ToolRow's disclosure check).
        expect(row.wordsGrew, `words box: ${row.id}`).toBe(false);
      } else {
        expect(row.shimmer, `shimmer: ${row.id}`).toBe(false);
        expect(row.animations, `loops: ${row.id}`).toBe(0);
      }
    }
    // Running words rest dimmer than finished ones.
    expect(rows[1]!.color).not.toBe(rows[3]!.color);
  });

  for (const [name, reduced, motion] of [
    ["Reduce Motion", "reduce", undefined],
    ["the motion gate (reduced)", "no-preference", "reduced"],
    ["the motion gate (off)", "no-preference", "off"],
  ] as const) {
    test(`${name}: running words hold still, dimmed, with no mark at the edge`, async () => {
      const rows = await measure(reduced, motion);
      console.log(`TOOL_ROW_SHIMMER ${name} ${JSON.stringify(rows)}`);
      for (const row of rows) {
        expect(row.spinners, `spinner: ${row.id}`).toBe(0);
        expect(row.detachedMarks, `mark at the far edge: ${row.id}`).toBe(0);
        expect(row.shimmer, `shimmer: ${row.id}`).toBe(false);
        expect(row.animations, `loops: ${row.id}`).toBe(0);
      }
      expect(rows[1]!.color).not.toBe(rows[3]!.color);
    });
  }
});
