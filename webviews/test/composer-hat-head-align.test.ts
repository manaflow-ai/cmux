// l10n-allow-file: gallery fixture names are test data.
// The composer hat's folded header keeps every icon on its text row's centre line, through a subagent
// hand-over (Leo, 2026-11-22, on "1 subagent · 1 subagent done · 1 stopped   17h 4m 46s": "now some of
// the icons are misaligned. chief among them is the little sidebar button. it's misaligned. well it's
// the background tasks", then "idk tho that might just be the switch over from one completing
// subagent to another"). The header grew to 34px (trayHeadHeight.experiment.ts `roomy`) while the
// Background tasks button over it kept the lines' 28px row from the header's top: its icon sat 3px
// above the counts and the chevron. subagents.css now sizes the header by one property
// (`--acpmux-tray-head-height`) and centres the button on it.
//
// Real Chromium (Playwright), the gallery's `agent-pane.composer-hat-head-align`: at 420px (a half
// split) and 900px, in each header height, every kind's mark, the time, the panel button's icon and the
// chevron centre on the counts' line box within 0.5px; then, as the running subagent finishes and the
// next starts, the header's height and the panel button and chevron hold still on every frame.
import { afterAll, beforeAll, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser, type Page } from "playwright";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";
import { installPaintedFrames } from "./support/paintedFrames";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("composer-hat-head-align.test.ts", async () => {
  setDefaultTimeout(180_000);
  const ENTRY = "agent-pane.composer-hat-head-align";
  const { createServer } = await import("vite");
  let server: Awaited<ReturnType<typeof createServer>>;
  let browser: Browser;

  beforeAll(async () => {
    server = await createServer({
      root: path.resolve(import.meta.dir, ".."),
      configFile: path.resolve(import.meta.dir, "../vite.config.gallery-dev.ts"),
      server: { port: 0, host: "127.0.0.1", strictPort: false },
      logLevel: "error",
    });
    await server.listen();
    browser = await chromium.launch({ headless: true });
    await warmGalleryFrame(server, ENTRY, { browser, params: { variant: "mixed" } });
  });

  afterAll(async () => {
    await browser?.close();
    await server?.close();
  });

  const open = async (width: number, widthName: string, arm: string): Promise<Page> => {
    const port = (server.httpServer!.address() as { port: number }).port;
    const page = await browser.newPage({ viewport: { width, height: 400 }, deviceScaleFactor: 2 });
    await page.goto(
      `http://127.0.0.1:${port}${galleryFrame(ENTRY, { variant: "mixed", width: widthName, exp: "subagent-tray-head-height", arm })}`,
    );
    await page.waitForFunction(() => document.documentElement.dataset.galleryReady === "1");
    await page.waitForSelector(".acpmux-running-tray__head .acpmux-running-tray__kind");
    await page.waitForSelector(".acpmux-running-tray__open");
    await installPaintedFrames(page);
    return page;
  };

  /** Each icon's vertical offset from the counts' line box centre, and the header's height. */
  const offsets = (page: Page) =>
    page.evaluate(() => {
      const head = document.querySelector<HTMLElement>(".acpmux-running-tray__head")!;
      const middle = (node: Element) => {
        const rect = node.getBoundingClientRect();
        return rect.top + rect.height / 2;
      };
      const line = middle(head.querySelector(".acpmux-running-tray__kind-text")!);
      const icons: Record<string, Element | null> = {
        panel: document.querySelector(".acpmux-running-tray__open > svg"),
        chevron: head.querySelector(".acpmux-running-tray__chevron svg"),
        time: head.querySelector(".acpmux-running-tray__time:not(:empty)"),
      };
      head.querySelectorAll(".acpmux-running-tray__kind").forEach((kind, index) => {
        icons[`kind ${index} (${(kind as HTMLElement).dataset.kind})`] = kind.querySelector(
          ":scope > svg, :scope > .acpmux-running-tray__stack-mark",
        );
        icons[`kind ${index} text`] = kind.querySelector(".acpmux-running-tray__kind-text");
      });
      return {
        head: head.getBoundingClientRect().height,
        text: head.textContent,
        off: Object.fromEntries(
          Object.entries(icons).flatMap(([name, node]) => (node ? [[name, middle(node) - line]] : [])),
        ) as Record<string, number>,
      };
    });

  const expectCentred = (read: Awaited<ReturnType<typeof offsets>>, at: string) => {
    const report = `${at}: ${JSON.stringify(read)}`;
    expect(read.off.panel, report).toBeDefined();
    expect(read.off.chevron, report).toBeDefined();
    for (const [name, off] of Object.entries(read.off))
      expect(Math.abs(off), `${name} ${report}`).toBeLessThanOrEqual(0.5);
  };

  for (const arm of ["roomy", "row", "tall"])
    for (const [width, widthName] of [
      [420, "narrow"],
      [900, "normal"],
    ] as const)
      test(`${arm} header at ${width}px: every icon on the counts' centre line, through a hand-over`, async () => {
        const page = await open(width, widthName, arm);
        try {
          const mixed = await offsets(page);
          expect(mixed.text).toContain("1 stopped");
          expectCentred(mixed, "one runs, one done, one stopped");
          // The hand-over, sampled every frame: the running one finishes, then the next starts.
          const drift = await page.evaluate(async () => {
            const read = () => {
              const panel = document.querySelector(".acpmux-running-tray__open > svg")!.getBoundingClientRect();
              const chevron = document.querySelector(".acpmux-running-tray__chevron svg")!.getBoundingClientRect();
              const head = document.querySelector(".acpmux-running-tray__head")!.getBoundingClientRect();
              return [panel.left, panel.top, chevron.left, chevron.top, head.height, head.top];
            };
            const seen = [read()];
            const frames = async (count: number) => {
              for (let index = 0; index < count; index += 1) {
                await window.cmuxPaintFrame();
                seen.push(read());
              }
            };
            document.querySelector<HTMLElement>('[data-stage="finish"]')!.click();
            await frames(30);
            document.querySelector<HTMLElement>('[data-stage="next"]')!.click();
            await frames(30);
            const span = (index: number) =>
              Math.max(...seen.map((sample) => sample[index]!)) - Math.min(...seen.map((sample) => sample[index]!));
            return {
              panelX: span(0),
              panelY: span(1),
              chevronX: span(2),
              chevronY: span(3),
              headHeight: span(4),
              headTop: span(5),
            };
          });
          for (const [name, moved] of Object.entries(drift))
            expect(moved, `${name} moved across the hand-over: ${JSON.stringify(drift)}`).toBeLessThanOrEqual(0.5);
          await page.waitForFunction(() => document.querySelector('[data-stage-phase="2"]'));
          const next = await offsets(page);
          expect(next.head).toBe(mixed.head);
          expectCentred(next, "the next one runs");
        } finally {
          await page.close();
        }
      });
});
