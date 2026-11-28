// An opened message run keeps one row rhythm (Leo, 2026-11-17: "why is there this big gap when i have
// s**t expanded"). In a turn the agent ran on its own, the rows its events made carry that turn
// (`inBackground`) and another agent's message steered into it does not, so each tool row under the
// run's line or under "Received N messages" took the 32 px gap that opens a background turn (model.ts
// `opensBackgroundTurn`). agent-pane.opened-run-rhythm replays that turn through the pane's client;
// this opens the run while the turn runs, reads the same rows once it ended (drawn where they ran),
// and checks each row of that work sits flush on the one above it (22 px apart,
// design/transcript-spacing.md).
import { afterAll, beforeAll, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser, type Page } from "playwright";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { devHighlightWorker } from "./support/devHighlightWorker";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";
import { installPaintedFrames } from "./support/paintedFrames";

await requireBrowserLane("opened-run-rhythm-browser.test.ts", async () => {
  setDefaultTimeout(180_000);
  const ENTRY = "agent-pane.opened-run-rhythm";
  const WIDTH = 640;
  const HEIGHT = 520;

  let server: Awaited<ReturnType<typeof import("vite").createServer>>;
  let browser: Browser;
  let base: string;
  beforeAll(async () => {
    const { createServer } = await import("vite");
    const root = path.resolve(import.meta.dir, "..");
    server = await createServer({
      root,
      configFile: path.join(root, "vite.config.ts"),
      server: { port: 0, host: "127.0.0.1" },
      plugins: [devHighlightWorker()],
      logLevel: "error",
    });
    await server.listen();
    base = `http://127.0.0.1:${(server.httpServer!.address() as { port: number }).port}`;
    browser = await chromium.launch({ headless: true });
    await warmGalleryFrame(server, ENTRY, { browser, params: { variant: "running" } });
  });
  afterAll(async () => {
    await browser?.close();
    await server?.close();
  });

  type Row = { id: string; kind: string; top: number; height: number; text: string };

  const settle = (page: Page) =>
    page.evaluate(async () => {
      await document.fonts.ready;
      for (let frame = 0; frame < 4; frame += 1) await window.cmuxPaintFrame();
    });

  /** Every drawn row in transcript order, top relative to the scroller's top. */
  const rows = (page: Page): Promise<Row[]> =>
    page.evaluate(() => {
      const scroller = document.querySelector<HTMLElement>(".acpmux-scroll");
      const origin = scroller ? scroller.getBoundingClientRect().top : 0;
      return [...document.querySelectorAll<HTMLElement>("article[data-row-id]")]
        .map((el) => {
          const r = el.getBoundingClientRect();
          const kind = [...el.classList].find((c) => c.startsWith("acpmux-") && !c.startsWith("acpmux-row")) ?? "";
          return {
            id: el.dataset.rowId!,
            kind,
            top: r.top - origin,
            height: r.height,
            text: (el.textContent ?? "").replace(/\s+/g, " ").trim().slice(0, 48),
          };
        })
        .filter((row) => row.height > 0)
        .sort((a, b) => a.top - b.top);
    });

  async function openRun(variant: "running" | "ended") {
    const page = await browser.newPage({ viewport: { width: WIDTH, height: HEIGHT }, colorScheme: "dark" });
    await installPaintedFrames(page);
    await page.addInitScript(() => {
      (globalThis as { cmuxExperiments?: Record<string, string> }).cmuxExperiments = {
        "background-turn-look": "line",
        "claude-turn-fold": "runs",
        "live-turn-work": "runs",
      };
    });
    await page.goto(
      `${base}${galleryFrame(ENTRY, { variant, theme: "Apple System Colors", colorScheme: "dark", width: WIDTH, height: HEIGHT })}`,
    );
    await page.locator("article[data-row-id]").first().waitFor();
    await settle(page);
    // Running, the woken turn's work folds into one message run: open it. Ended, the turn draws its
    // rows where they ran, each call on its own row, with no run line.
    if (variant === "running") {
      await page.locator("[data-message-run]").first().click();
      await settle(page);
    }
    return page;
  }

  /** What an opened run draws: tool rows, another agent's lines and their "Received N messages". */
  const RUN_KINDS = new Set(["acpmux-activity", "acpmux-laneNoticeBatch", "acpmux-user"]);
  /** The woken turn's rows: from the run's line (or its first tool row) through its last row of work. */
  function revealed(all: Row[]): Row[] {
    const start = all.findIndex((row) => row.id.startsWith("messageRun-") || row.kind === "acpmux-activity");
    if (start < 0) return [];
    let end = start + 1;
    while (end < all.length && RUN_KINDS.has(all[end]!.kind)) end += 1;
    return all.slice(start, end);
  }

  const table = (all: Row[]) =>
    all
      .map(
        (row) =>
          `${row.top.toFixed(1).padStart(7)} +${row.height.toFixed(1).padStart(5)}  ${row.kind.padEnd(24)} ${row.text}`,
      )
      .join("\n");

  for (const variant of ["running", "ended"] as const) {
    test(`${variant}: every row of the woken turn's work sits flush on the one above`, async () => {
      const page = await openRun(variant);
      try {
        const all = await rows(page);
        const run = revealed(all);
        // Running: the run's line, "Write round 4 script", "Received 3 messages", the read and two
        // commands, the last message. Ended: the same rows without the line.
        const failures: string[] = [];
        if (run.length < 4) failures.push(`expected the woken turn's rows, found ${run.length}`);
        for (let at = 1; at < run.length; at += 1) {
          const above = run[at - 1]!;
          const row = run[at]!;
          const gap = row.top - (above.top + above.height);
          if (Math.abs(gap) > 0.5) failures.push(`${gap.toFixed(1)} px between "${above.text}" and "${row.text}"`);
        }
        if (failures.length || process.env.OPENED_RUN_TABLE === "1") console.log(`${variant}\n${table(all)}`);
        expect(failures).toEqual([]);
      } finally {
        await page.close();
      }
    });
  }
});
