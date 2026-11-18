// A long block in a transcript row scrolls in its own box and mounts only the lines in that box's
// view (lineWindow.ts), in a real engine: the box and the reader's row under it never move while the
// box scrolls (0 px), a line on screen stays where it was through each step, wrapped lines included,
// a selection dragged across the window copies every line it spans, and the mounted lines are the
// same for 1,000 and 10,000. The page is browser/transcript-block-lines.harness.tsx. With
// BLOCK_LINES_MEASURE=1 it prints the counts and timings the PR quotes.
import { afterAll, beforeAll, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser, type Page } from "playwright";
import type { BlockKind } from "./browser/transcript-block-lines.harness";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { warmViteServer } from "./support/warmDevServer";

await requireBrowserLane("transcript-block-lines-window-browser.test.ts", async () => {
  setDefaultTimeout(180_000);
  const { createServer } = await import("vite");
  const webviews = path.resolve(import.meta.dir, "..");
  const PAGE = "/test/browser/transcript-block-lines.html";
  let vite: Awaited<ReturnType<typeof createServer>> | undefined;
  let browser: Browser;
  beforeAll(async () => {
    vite = await createServer({
      root: webviews,
      configFile: path.join(webviews, "vite.config.ts"),
      server: { port: 0, host: "127.0.0.1", strictPort: false },
      logLevel: "error",
    });
    await vite.listen();
    await warmViteServer(vite, PAGE);
    browser = await chromium.launch({
      headless: true,
      ...(process.env.CMUX_BROWSER_EXECUTABLE ? { executablePath: process.env.CMUX_BROWSER_EXECUTABLE } : {}),
    });
  });
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });

  const open = async (kind: BlockKind, lines: number, reveal = 0): Promise<Page> => {
    const page = await browser.newPage({ viewport: { width: 900, height: 700 } });
    const { port } = vite!.httpServer!.address() as { port: number };
    await page.goto(`http://127.0.0.1:${port}${PAGE}`);
    await page.waitForFunction(() => "__blockLines" in window);
    await page.evaluate(
      ([kind, lines, reveal]) =>
        (window as unknown as { __blockLines: { draw(k: string, n: number, r: number): void } }).__blockLines.draw(
          kind as string,
          lines as number,
          reveal as number,
        ),
      [kind, lines, reveal] as const,
    );
    await page.waitForSelector("[data-preview]");
    await frames(page, 3);
    return page;
  };
  const frames = (page: Page, count: number) =>
    page.evaluate(
      (count) =>
        new Promise<void>((done) => {
          let left = count;
          const tick = () => (--left <= 0 ? done() : requestAnimationFrame(tick));
          requestAnimationFrame(tick);
        }),
      count,
    );
  const counts = (page: Page) =>
    page.evaluate(() => {
      const box = document.querySelector("[data-preview]")!;
      return {
        lines: box.querySelectorAll(".cv-line, .cv-code-plain__line").length,
        nodes: document.getElementById("column")!.querySelectorAll("*").length,
      };
    });

  /// Scrolls the box `steps` times by `step` px, a frame each, and reports how far the box and the
  /// reader's row moved, how often a line on screen did not move with the scroll, and the frames.
  const scrollThrough = (page: Page, steps: number, step: number) =>
    page.evaluate(
      async ([steps, step]) => {
        const box = document.querySelector<HTMLElement>("[data-preview]")!;
        const column = document.getElementById("column")!;
        const reader = document.getElementById("reader")!;
        const lineSelector = ".cv-line, .cv-code-plain__line";
        const frame = () => new Promise<number>((done) => requestAnimationFrame(done));
        const top = (node: Element) => node.getBoundingClientRect().top - column.getBoundingClientRect().top;
        const boxTop = top(box);
        const boxHeight = box.getBoundingClientRect().height;
        const readerTop = top(reader);
        let drift = 0;
        let jumps = 0;
        let mounted = 0;
        const deltas: number[] = [];
        let last = await frame();
        for (let index = 0; index < steps; index++) {
          const edge = box.getBoundingClientRect().top;
          const held = [...box.querySelectorAll(lineSelector)].find(
            (line) => line.getBoundingClientRect().bottom > edge + 1,
          );
          const before = held?.getBoundingClientRect().top ?? 0;
          const from = box.scrollTop;
          box.scrollTop = from + step;
          const moved = box.scrollTop - from;
          const now = await frame();
          deltas.push(now - last);
          last = now;
          if (held?.isConnected && Math.abs(held.getBoundingClientRect().top - (before - moved)) > 1) jumps++;
          drift = Math.max(
            drift,
            Math.abs(top(box) - boxTop),
            Math.abs(box.getBoundingClientRect().height - boxHeight),
            Math.abs(top(reader) - readerTop),
          );
          mounted = Math.max(mounted, box.querySelectorAll(lineSelector).length);
        }
        deltas.sort((a, b) => a - b);
        return { drift, jumps, mounted, p95: deltas[Math.floor(deltas.length * 0.95)] ?? 0 };
      },
      [steps, step] as const,
    );

  /// One resize step of the column: the layout it costs, in ms.
  const resizeCost = (page: Page) =>
    page.evaluate(async () => {
      const column = document.getElementById("column")!;
      const times: number[] = [];
      for (let index = 0; index < 20; index++) {
        await new Promise((done) => requestAnimationFrame(done));
        const started = performance.now();
        column.style.width = `${index % 2 ? 640 : 600}px`;
        // Reading the box's content height forces the layout the step costs.
        if (document.querySelector("[data-preview]")!.scrollHeight < 0) break;
        times.push(performance.now() - started);
      }
      times.sort((a, b) => a - b);
      return times[Math.floor(times.length * 0.95)] ?? 0;
    });

  const measure = process.env.BLOCK_LINES_MEASURE === "1";
  for (const kind of ["shell", "output", "read"] as const) {
    test(`${kind}: the same lines at 1,000 and 10,000, and nothing moves while its box scrolls`, async () => {
      const seen: { lines: number; nodes: number }[] = [];
      for (const lines of [1_000, 10_000]) {
        // A read draws plain past the highlight limit of 2,000 lines (highlightLimits.ts).
        const page = await open(kind, kind === "read" ? Math.max(lines, 3_000) : lines);
        try {
          const before = await counts(page);
          seen.push(before);
          const scrolled = await scrollThrough(page, 120, 37);
          const resize = await resizeCost(page);
          if (measure)
            console.log(
              `block-lines ${kind} ${lines}: ${JSON.stringify({ ...before, ...scrolled, resizeP95: resize })}`,
            );
          expect(scrolled.drift).toBe(0);
          expect(scrolled.jumps).toBe(0);
          expect(scrolled.mounted).toBeLessThanOrEqual(40);
        } finally {
          await page.close();
        }
      }
      expect(seen[0]!.lines).toBeLessThanOrEqual(40);
      expect(Math.abs(seen[1]!.nodes - seen[0]!.nodes)).toBeLessThanOrEqual(seen[0]!.nodes * 0.1);
    });
  }

  test("a selection dragged across the window copies every line it spans", async () => {
    const page = await open("shell", 10_000);
    try {
      const text = await page.evaluate(async () => {
        const box = document.querySelector<HTMLElement>("[data-preview]")!;
        const frame = () => new Promise((done) => requestAnimationFrame(done));
        // A finished output draws its last 400 lines: the drag starts on the third one drawn.
        const start = [...box.querySelectorAll(".cv-line")][2]!;
        const selection = document.getSelection()!;
        selection.setBaseAndExtent(start.firstChild!, 0, start.firstChild!, 1);
        // The drag carries on down the box, a step a frame, the selection's end following it.
        for (let step = 0; step < 60; step++) {
          box.scrollTop += 90;
          await frame();
          const lines = [...box.querySelectorAll(".cv-line")];
          const last = lines.at(-1)!;
          selection.extend(last.firstChild!, last.textContent!.length - 1);
          await frame();
        }
        return selection.toString();
      });
      const lines = text.split("\n");
      expect(lines[0]).toBe("line 9602");
      // Every line from the start of the drag to its end, none missing.
      const numbers = lines.map((line) => Number(/^line (\d+)/.exec(line)?.[1]));
      expect(numbers.length).toBeGreaterThan(200);
      expect(numbers).toEqual(numbers.map((_, index) => 9602 + index));
    } finally {
      await page.close();
    }
  });

  test("Select All (Cmd-A) copies every line of a windowed box, and the box windows again once it is cleared", async () => {
    const page = await open("shell", 10_000);
    try {
      const { copied, during, after } = await page.evaluate(async () => {
        const box = document.querySelector<HTMLElement>("[data-preview]")!;
        const frame = () => new Promise((done) => requestAnimationFrame(done));
        const count = () => box.querySelectorAll(".cv-line").length;
        document.getSelection()!.selectAllChildren(document.body);
        await frame();
        await frame();
        const copied = document.getSelection()!.toString();
        const during = count();
        document.getSelection()!.removeAllRanges();
        await frame();
        await frame();
        return { copied, during, after: count() };
      });
      // The page's own text around the box (the command, the cut mark, the reader's row) is copied too.
      const numbers = copied
        .split("\n")
        .filter((line) => /^line \d+/.test(line))
        .map((line) => Number(/^line (\d+)/.exec(line)![1]));
      // The finished output's 400-line tail (toolOutputModel.ts), every line of it.
      expect(numbers).toEqual(Array.from({ length: 400 }, (_, index) => 9_600 + index));
      expect(during).toBe(401);
      expect(after).toBeLessThanOrEqual(40);
    } finally {
      await page.close();
    }
  });

  for (const kind of ["shell", "output", "read"] as const) {
    test(`${kind}: Find's reveal opens the box whole, and a match in its head is painted`, async () => {
      const total = kind === "read" ? 3_000 : 1_000;
      const page = await open(kind, total, 1);
      try {
        // Every line is drawn again, as before the window: Find's counts and highlights read them.
        expect((await counts(page)).lines).toBeGreaterThanOrEqual(total);
        const active = await page.evaluate(() =>
          (window as unknown as { __blockLines: { find(q: string, n: number): string | null } }).__blockLines.find(
            "line 5",
            0,
          ),
        );
        expect(active?.toLowerCase()).toBe("line 5");
      } finally {
        await page.close();
      }
    });
  }
});
