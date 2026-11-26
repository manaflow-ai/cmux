// A closed step row is one line and shows nothing of the lines after it (cmux#52930: a folded
// thought, "So the FFI pin is different from what I expected… > 3s", showed the top half of its
// second line under it, over the gap to the next row). The thought's line is clamped to one line
// (`-webkit-line-clamp`) and centred in the taller row; the clamp keeps the cut lines in the box and
// `overflow: hidden` clips at the padding edge, so the padding that centred it drew the next line's
// top. conversation.css `.cv-thought__preview` centres it with margins instead.
//
// Every one-line step row, drawn by its component with the pane's CSS (browser/thought-row-one-line
// .html): a finished thought alone and in an opened group (the lead too), a search and a command
// row, a running command, and a thought that streams and then folds. At every transcript spacing
// (tight, default, roomy), row air (6, 10, 12) and text scale (1, 1.2, 1.5), in Chromium and WebKit
// (the app's engine):
// - the line's clip box (its padding box: `overflow: hidden`) is one line tall, inside its row;
// - no glyph box of a later line reaches into it, beyond the overhang a font taller than its line
//   gives every glyph box (negative half-leading, no ink);
// - the row is the row height, so the next row starts where it always did.
// Opened, the thought's line shows every line, unclipped.
//
// Locally: CMUX_BROWSER_TESTS=1 bun test test/thought-row-one-line-browser.test.ts (CI or a Linux VM).
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, webkit, type Browser, type BrowserType, type Page } from "playwright";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { warmViteServer } from "./support/warmDevServer";

await requireBrowserLane("thought-row-one-line-browser.test.ts", async () => {
  setDefaultTimeout(240_000);
  const engines: [string, BrowserType][] = [];
  for (const engine of [
    ["chromium", chromium],
    ["webkit", webkit],
  ] as [string, BrowserType][]) {
    try {
      await (await engine[1].launch({ headless: true })).close();
      engines.push(engine);
    } catch {
      console.warn(`thought-row-one-line: skipping ${engine[0]}`);
    }
  }
  if (engines.length === 0) {
    describe.skip("one-line step rows", () => test("browsers", () => {}));
    return;
  }
  const { createServer } = await import("vite");
  let vite: Awaited<ReturnType<typeof createServer>>;
  let url = "";
  beforeAll(async () => {
    const root = path.resolve(import.meta.dir, "..");
    vite = await createServer({
      root,
      configFile: path.join(root, "vite.config.ts"),
      server: { port: 0, host: "127.0.0.1" },
      logLevel: "error",
    });
    await vite.listen();
    await warmViteServer(vite, "/test/browser/thought-row-one-line.html");
    const port = (vite.httpServer!.address() as { port: number }).port;
    url = `http://127.0.0.1:${port}/test/browser/thought-row-one-line.html`;
  });
  afterAll(async () => {
    await vite?.close();
  });

  /** The closed rows: a thought's line, or a tool row's words. */
  const CLOSED = [
    "thought",
    "thought-one-line",
    "step-thought",
    "step-thought-lead",
    "search",
    "command",
    "command-live",
  ];
  const SPACINGS = [null, "tight", "roomy"] as const;
  const AIRS = [null, "a", "c"] as const;
  const SCALES = [1, 1.2, 1.5];

  type Fault = { row: string; problem: string };
  /** Each named row's closed line, measured; a list of what is wrong. */
  const faults = (page: Page, ids: string[]): Promise<Fault[]> =>
    page.evaluate((ids) => {
      const out: Fault[] = [];
      for (const id of ids) {
        const host = document.querySelector<HTMLElement>(`[data-testid="${id}"]`);
        const row = host?.querySelector<HTMLElement>(".cv-tool");
        const line = row?.querySelector<HTMLElement>(":scope > .cv-thought__preview, :scope > .cv-tool__text");
        if (!row || !line) {
          out.push({ row: id, problem: "no row line" });
          continue;
        }
        const style = getComputedStyle(line);
        const pitch = Number.parseFloat(style.lineHeight);
        const box = line.getBoundingClientRect();
        // `overflow: hidden` clips at the padding box; the line has no border.
        const clip = { top: box.top, bottom: box.bottom };
        if (box.height > pitch + 0.5)
          out.push({ row: id, problem: `clip box ${box.height}px over one ${pitch}px line` });
        const rowBox = row.getBoundingClientRect();
        const rowHeight = Number.parseFloat(getComputedStyle(row).minHeight);
        if (Math.abs(rowBox.height - rowHeight) > 0.5)
          out.push({ row: id, problem: `row ${rowBox.height}px, not the ${rowHeight}px row height` });
        if (clip.top < rowBox.top - 0.5 || clip.bottom > rowBox.bottom + 0.5)
          out.push({ row: id, problem: "line drawn outside its row" });
        const range = document.createRange();
        range.selectNodeContents(line);
        const rects = [...range.getClientRects()].filter((rect) => rect.width > 0 && rect.height > 0);
        if (rects.length === 0) {
          out.push({ row: id, problem: "no text" });
          continue;
        }
        const first = Math.min(...rects.map((rect) => rect.top));
        for (const rect of rects) {
          if (rect.top < first + pitch / 2) continue;
          // A font taller than its line lets every glyph box overhang its line by half the excess.
          const overhang = Math.max(0, (rect.height - pitch) / 2);
          const shown = clip.bottom - rect.top - overhang;
          if (shown > 0.5) out.push({ row: id, problem: `a later line shows ${shown.toFixed(1)}px` });
        }
      }
      return out;
    }, ids);

  const setLook = (page: Page, spacing: string | null, air: string | null, scale: number) =>
    page.evaluate(
      ([spacing, air, scale]) => {
        const root = document.documentElement;
        if (spacing) root.dataset.transcriptToolSpacing = spacing as string;
        else delete root.dataset.transcriptToolSpacing;
        if (air) root.dataset.rowAir = air as string;
        else delete root.dataset.rowAir;
        root.style.setProperty("--cmux-chat-text-scale", String(scale));
        root.style.setProperty("--cv-font-size", `${14 * (scale as number)}px`);
      },
      [spacing, air, scale] as const,
    );

  for (const [name, engine] of engines)
    describe(`one-line step rows in ${name}`, () => {
      let browser: Browser;
      let page: Page;
      beforeAll(async () => {
        browser = await engine.launch({ headless: true });
        page = await browser.newPage({ viewport: { width: 600, height: 900 } });
        await page.goto(url);
        await page.waitForFunction(() => document.documentElement.dataset.harnessReady === "true");
      });
      afterAll(async () => {
        await browser?.close();
      });

      test("a closed row shows one line and nothing of the next, at every spacing, air and text scale", async () => {
        // The thought folds to its line, cut: it opens.
        await page.getByTestId("thought").locator("button.cv-thought").waitFor();
        const found: (Fault & { look: string })[] = [];
        for (const spacing of SPACINGS)
          for (const air of AIRS)
            for (const scale of SCALES) {
              await setLook(page, spacing, air, scale);
              const look = `spacing ${spacing ?? "default"}, air ${air ?? "default"}, scale ${scale}`;
              for (const fault of await faults(page, CLOSED)) found.push({ ...fault, look });
            }
        expect(found).toEqual([]);
        await setLook(page, null, null, 1);
      });

      test("a thought that streamed folds to one line once done", async () => {
        const host = page.getByTestId("streamed-thought");
        // While it streams it reads "Thinking" over its text, no line cut.
        await host.locator(".cv-thought.is-full").waitFor();
        await page.evaluate(() => (window as unknown as { finishThought: () => void }).finishThought());
        await host.locator("button.cv-thought").waitFor();
        for (const spacing of SPACINGS)
          for (const scale of SCALES) {
            await setLook(page, spacing, null, scale);
            expect(await faults(page, ["streamed-thought"])).toEqual([]);
          }
        await setLook(page, null, null, 1);
      });

      test("opened, the thought's line shows every line it wraps to", async () => {
        const toggle = page.getByTestId("thought").locator("button.cv-thought");
        await toggle.click();
        await page.locator('[data-testid="thought"] button.cv-thought[aria-expanded="true"]').waitFor();
        await page.waitForFunction(() => {
          const line = document.querySelector('[data-testid="thought"] .cv-thought__preview');
          return line && line.getAnimations().length === 0 && line.getBoundingClientRect().height > 30;
        });
        const open = await page.evaluate(() => {
          const line = document.querySelector<HTMLElement>('[data-testid="thought"] .cv-thought__preview')!;
          return {
            scroll: line.scrollHeight,
            client: line.clientHeight,
            pitch: parseFloat(getComputedStyle(line).lineHeight),
          };
        });
        expect(open.client).toBeGreaterThanOrEqual(open.pitch * 2);
        expect(open.scroll).toBeLessThanOrEqual(open.client + 1);
        await toggle.click();
      });
    });
});
