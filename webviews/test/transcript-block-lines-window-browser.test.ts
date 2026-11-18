// A long block in a transcript row scrolls in its own box and mounts only the lines in that box's
// view (lineWindow.ts), in a real engine: the box and the reader's row under it never move while the
// box scrolls (0 px), a line on screen stays where it was through each step, wrapped lines included,
// a selection dragged across the window copies every line it spans, and the mounted lines are the
// same for 1,000 and 10,000. The page is browser/transcript-block-lines.harness.tsx. With
// BLOCK_LINES_MEASURE=1 it prints the counts and timings the PR quotes.
import { afterAll, beforeAll, expect, setDefaultTimeout, test } from "bun:test";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { chromium, type Browser, type Page } from "playwright";
import type { BlockKind } from "./browser/transcript-block-lines.harness";
import { HIGHLIGHT_WORKER_FILE } from "../src/agent-session/acpmux/conversation/highlightPool";
import { builtHighlightWorker, devHighlightWorker } from "./support/devHighlightWorker";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { warmViteServer } from "./support/warmDevServer";

await requireBrowserLane("transcript-block-lines-window-browser.test.ts", async () => {
  setDefaultTimeout(180_000);
  const { createServer } = await import("vite");
  const webviews = path.resolve(import.meta.dir, "..");
  const PAGE = "/test/browser/transcript-block-lines.html";
  // By default the page is a production build (vite.config.ts's build, the harness as its one input),
  // served as static files with the shipped highlight worker beside it, as the app loads it; with
  // BLOCK_LINES_DEV=1, the Vite dev server with Pierre's own worker. The build takes about 6 s.
  const built = process.env.BLOCK_LINES_DEV !== "1";
  let vite: Awaited<ReturnType<typeof createServer>> | undefined;
  let statics: ReturnType<typeof Bun.serve> | undefined;
  let out: string | undefined;
  let origin = "";
  let browser: Browser;
  beforeAll(async () => {
    if (built) {
      out = fs.mkdtempSync(path.join(process.env.TMPDIR ?? os.tmpdir(), "block-lines-build-"));
      await buildPage(out);
      const root = out;
      statics = Bun.serve({
        port: 0,
        hostname: "127.0.0.1",
        // The config's base is relative ("./"): the page at test/browser/ asks for its chunks, assets and
        // worker beside it, and they are written at the build's root.
        async fetch(request) {
          const wanted = decodeURIComponent(new URL(request.url).pathname);
          for (const candidate of [wanted, wanted.replace(/^\/test\/browser\//, "/")]) {
            const file = Bun.file(path.join(root, candidate));
            if (await file.exists()) return new Response(file);
          }
          return new Response("not found", { status: 404 });
        },
      });
      origin = `http://127.0.0.1:${statics.port}`;
    } else {
      vite = await createServer({
        root: webviews,
        configFile: path.join(webviews, "vite.config.ts"),
        server: { port: 0, host: "127.0.0.1", strictPort: false },
        logLevel: "error",
        // The dev server serves no built highlight worker (#25876): a highlighted read runs Pierre's own.
        plugins: [devHighlightWorker()],
      });
      await vite.listen();
      await warmViteServer(vite, PAGE);
      origin = `http://127.0.0.1:${(vite.httpServer!.address() as { port: number }).port}`;
    }
    browser = await chromium.launch({
      headless: true,
      ...(process.env.CMUX_BROWSER_EXECUTABLE ? { executablePath: process.env.CMUX_BROWSER_EXECUTABLE } : {}),
    });
  });
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
    await statics?.stop(true);
    if (out) fs.rmSync(out, { recursive: true, force: true });
  });

  /// The production build of the page into `outDir`: the app's Vite config (its plugins, chunking and
  /// minification) with the harness as its only input, and the pane's highlight worker built as
  /// build-agent-pane-web.sh builds it, beside the page, where the pool starts it.
  async function buildPage(outDir: string) {
    const { build, loadConfigFromFile } = await import("vite");
    // bun test sets NODE_ENV=test, which makes the JSX transform emit its dev calls against React's
    // production build: build as `vite build` does, then put it back.
    const nodeEnv = process.env.NODE_ENV;
    process.env.NODE_ENV = "production";
    const loaded = await loadConfigFromFile(
      { command: "build", mode: "production" },
      path.join(webviews, "vite.config.ts"),
    );
    const config = loaded!.config;
    await build({
      ...config,
      configFile: false,
      root: webviews,
      logLevel: "error",
      plugins: [...(config.plugins ?? []), builtHighlightWorker()],
      build: {
        ...config.build,
        outDir,
        emptyOutDir: true,
        rolldownOptions: { ...config.build?.rolldownOptions, input: { harness: path.join(webviews, PAGE.slice(1)) } },
      },
    }).finally(() => {
      process.env.NODE_ENV = nodeEnv;
    });
    const worker = Bun.spawnSync(
      [
        "bun",
        "scripts/agent-pane/bundle.mjs",
        "node_modules/@pierre/diffs/dist/worker/worker.js",
        "src/agent-session/acpmux/shiki",
        path.join(outDir, HIGHLIGHT_WORKER_FILE),
      ],
      { cwd: webviews, stderr: "pipe" },
    );
    if (worker.exitCode !== 0) throw new Error(`highlight worker bundle failed: ${worker.stderr.toString()}`);
  }

  /// The highlight worker scripts each page started: in the build, the shipped highlight-worker.js.
  const workers = new WeakMap<Page, string[]>();
  const open = async (kind: BlockKind, lines: number, reveal = 0): Promise<Page> => {
    const page = await browser.newPage({ viewport: { width: 900, height: 700 } });
    const started: string[] = [];
    workers.set(page, started);
    page.on("worker", (worker) => started.push(new URL(worker.url()).pathname));
    await page.goto(`${origin}${PAGE}`);
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
    // The handle would keep the box alive after it unmounts: let it go.
    await (await page.waitForSelector("[data-preview]")).dispose();
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
        // A highlighted read's lines are in Pierre's shadow root.
        const lineList = () => [
          ...box.querySelectorAll(lineSelector),
          ...(box.querySelector("diffs-container")?.shadowRoot?.querySelectorAll("[data-line]") ?? []),
        ];
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
          const held = lineList().find((line) => line.getBoundingClientRect().bottom > edge + 1);
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
          mounted = Math.max(mounted, lineList().length);
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
  // A read within the highlight limits draws in Pierre's shadow root (HighlightedLines.tsx), windowed
  // by Pierre's own virtualizer on the read's box (usePierreCode.ts), its gutter in step with it.
  const painted = async (page: Page) => {
    await paintedLines(page);
    if (built) expect(workers.get(page)).toContain(`/test/browser/${HIGHLIGHT_WORKER_FILE}`);
  };
  const paintedLines = (page: Page) =>
    page.waitForFunction(() => {
      const host = document.querySelector("[data-preview] diffs-container");
      // Tokens colored: the worker's highlight has come back.
      return (
        Boolean(host?.shadowRoot?.querySelector("[data-line] span[style]")) &&
        !document.querySelector(".cv-code-plain__line")
      );
    });
  const shadowCounts = (page: Page) =>
    page.evaluate(() => {
      const shadow = document.querySelector("[data-preview] diffs-container")!.shadowRoot!;
      return { nodes: shadow.querySelectorAll("*").length, lines: shadow.querySelectorAll("[data-line]").length };
    });
  /// Whether the gutter's numbers sit beside the lines Pierre draws: its first number is the first drawn
  /// line's, at that line's height, and it has as many numbers as there are lines drawn.
  const gutterInStep = (page: Page) =>
    page.evaluate(() => {
      const gutter = document.querySelector<HTMLElement>(".cv-filepeek__gutter")!;
      const lines = [
        ...document
          .querySelector("[data-preview] diffs-container")!
          .shadowRoot!.querySelectorAll<HTMLElement>("[data-line]"),
      ];
      const numbers = (gutter.textContent ?? "").split("\n");
      const top = gutter.getBoundingClientRect().top + parseFloat(getComputedStyle(gutter).paddingTop);
      return {
        first: Number(numbers[0]) === Number(lines[0]!.dataset.line),
        offset: Math.abs(lines[0]!.getBoundingClientRect().top - top),
        count: numbers.length === lines.length,
      };
    });

  test("code: a highlighted read mounts the same lines at 200, 1,000 and 2,000, its gutter in step, and nothing moves while its box scrolls", async () => {
    const seen: { lines: number; nodes: number }[] = [];
    for (const lines of [200, 1_000, 2_000]) {
      const page = await open("code", lines);
      try {
        await painted(page);
        await frames(page, 3);
        const before = await shadowCounts(page);
        seen.push(before);
        expect(await gutterInStep(page)).toEqual({ first: true, offset: 0, count: true });
        const scrolled = await scrollThrough(page, 120, 37);
        await frames(page, 3);
        const resize = await resizeCost(page);
        if (measure)
          console.log(`block-lines code ${lines}: ${JSON.stringify({ ...before, ...scrolled, resizeP95: resize })}`);
        expect(scrolled.drift).toBe(0);
        expect(scrolled.jumps).toBe(0);
        // The box's eight lines and a box of them past each edge.
        expect(scrolled.mounted).toBeLessThanOrEqual(32);
        expect(await gutterInStep(page)).toEqual({ first: true, offset: 0, count: true });
      } finally {
        await page.close();
      }
    }
    expect(seen[0]!.lines).toBeLessThanOrEqual(32);
    expect(Math.abs(seen[2]!.nodes - seen[0]!.nodes)).toBeLessThanOrEqual(seen[0]!.nodes * 0.1);
  });

  test("code: a line far down inside a block comment is colored as one, so the window reads the lines above it", async () => {
    const page = await open("code", 2_000);
    try {
      await painted(page);
      const colors = await page.evaluate(async () => {
        const box = document.querySelector<HTMLElement>("[data-preview]")!;
        const shadow = box.querySelector("diffs-container")!.shadowRoot!;
        const frame = () => new Promise((done) => requestAnimationFrame(done));
        box.scrollTop = 1_538 * 20;
        for (let index = 0; index < 6; index++) await frame();
        const color = (line: number) =>
          [...shadow.querySelectorAll(`[data-line="${line}"] span`)].map((span) => getComputedStyle(span).color);
        return { opens: color(1_541), inside: color(1_542), after: color(1_544) };
      });
      expect(colors.inside.length).toBeGreaterThan(0);
      // Every token of the line inside the comment is the comment's color, not the code's after it.
      expect(new Set(colors.inside)).toEqual(new Set([colors.opens[0]]));
      expect(colors.after).not.toContain(colors.opens[0]);
    } finally {
      await page.close();
    }
  });

  test("code: Find's reveal draws a highlighted read whole, as before", async () => {
    const page = await open("code", 2_000, 1);
    try {
      await painted(page);
      await frames(page, 3);
      expect((await shadowCounts(page)).lines).toBe(2_000);
      expect(await gutterInStep(page)).toEqual({ first: true, offset: 0, count: true });
    } finally {
      await page.close();
    }
  });

  test("code: Select All draws a highlighted read whole, and it windows again once cleared", async () => {
    const page = await open("code", 2_000);
    try {
      await painted(page);
      const { during, after, held } = await page.evaluate(async () => {
        const box = document.querySelector<HTMLElement>("[data-preview]")!;
        const shadow = box.querySelector("diffs-container")!.shadowRoot!;
        const frame = () => new Promise((done) => requestAnimationFrame(done));
        box.scrollTop = 900 * 20;
        for (let index = 0; index < 4; index++) await frame();
        const line = () => shadow.querySelector<HTMLElement>("[data-line]")!;
        const edge = box.getBoundingClientRect().top;
        const top = [...shadow.querySelectorAll<HTMLElement>("[data-line]")].find(
          (node) => node.getBoundingClientRect().top >= edge,
        )!;
        const before = top.getBoundingClientRect().top;
        document.getSelection()!.selectAllChildren(document.body);
        for (let index = 0; index < 4; index++) await frame();
        const during = shadow.querySelectorAll("[data-line]").length;
        const again = shadow.querySelector<HTMLElement>(`[data-line="${top.dataset.line}"]`)!;
        const held = Math.abs(again.getBoundingClientRect().top - before);
        document.getSelection()!.removeAllRanges();
        for (let index = 0; index < 4; index++) await frame();
        return { during, after: shadow.querySelectorAll("[data-line]").length, held, first: line().dataset.line };
      });
      expect(during).toBe(2_000);
      expect(held).toBe(0);
      expect(after).toBeLessThanOrEqual(32);
      expect(await gutterInStep(page)).toEqual({ first: true, offset: 0, count: true });
    } finally {
      await page.close();
    }
  });

  test("code: a selection dragged inside a highlighted read across its window copies every line it spans", async () => {
    const page = await open("code", 2_000);
    try {
      await painted(page);
      const text = await page.evaluate(async () => {
        const box = document.querySelector<HTMLElement>("[data-preview]")!;
        const shadow = box.querySelector("diffs-container")!.shadowRoot!;
        const frame = () => new Promise((done) => requestAnimationFrame(done));
        const lineText = (line: Element) => line.querySelector("span")!.firstChild!;
        const selection = document.getSelection()!;
        const start = shadow.querySelector('[data-line="3"]')!;
        selection.setBaseAndExtent(lineText(start), 0, lineText(start), 1);
        // The drag carries on down the box, a step a frame, the selection's end following it.
        for (let step = 0; step < 40; step++) {
          box.scrollTop += 90;
          await frame();
          const last = [...shadow.querySelectorAll("[data-line]")].at(-1)!;
          selection.extend(lineText(last), 1);
          await frame();
        }
        return selection.toString();
      });
      const numbers = text
        .split("\n")
        .map((line) => Number(/(?:line|inside|comment|closes) ?(\d+)/.exec(line)?.[1]))
        .filter((value) => !Number.isNaN(value));
      expect(numbers[0]).toBe(2);
      expect(numbers.length).toBeGreaterThan(150);
      expect(numbers).toEqual(numbers.map((_, index) => 2 + index));
    } finally {
      await page.close();
    }
  });

  test("code: a screen reader meets one region named with the true count, Pierre's rows items placed in the whole", async () => {
    const page = await open("code", 2_000);
    try {
      await painted(page);
      await page.evaluate(async () => {
        const box = document.querySelector<HTMLElement>("[data-preview]")!;
        box.scrollTop = 1_000 * 20;
        for (let index = 0; index < 4; index++) await new Promise((done) => requestAnimationFrame(done));
      });
      const dom = await page.evaluate(() => {
        const box = document.querySelector<HTMLElement>("[data-preview]")!;
        const rows = [
          ...box.querySelector("diffs-container")!.shadowRoot!.querySelectorAll<HTMLElement>("[data-line]"),
        ];
        return {
          label: box.getAttribute("aria-label"),
          role: box.getAttribute("role"),
          tabindex: box.getAttribute("tabindex"),
          list: rows[0]!.parentElement!.getAttribute("role"),
          roles: [...new Set(rows.map((row) => row.getAttribute("role")))],
          sizes: [...new Set(rows.map((row) => row.getAttribute("aria-setsize")))],
          places: rows.map((row) => Number(row.getAttribute("aria-posinset"))),
          lines: rows.map((row) => Number(row.dataset.line)),
        };
      });
      expect(dom).toMatchObject({
        label: "big.ts, 2,000 lines",
        role: "region",
        tabindex: "0",
        list: "list",
        roles: ["listitem"],
        sizes: ["2000"],
      });
      // Each drawn row is at its own line's place in the whole read, in order, around line 1,000.
      expect(dom.places).toEqual(dom.lines);
      expect(dom.places).toEqual(dom.places.map((_, index) => dom.places[0]! + index));
      expect(dom.places[0]!).toBeGreaterThan(960);

      // The browser's own accessibility tree, across Pierre's shadow root: the region by its name,
      // a list in it, and its items, as many as are drawn. (CDP lists no posinset or setsize for a
      // listitem, a plain block's included; the attributes above carry them.)
      const cdp = await page.context().newCDPSession(page);
      const { nodes } = (await cdp.send("Accessibility.getFullAXTree")) as {
        nodes: {
          nodeId: string;
          parentId?: string;
          role?: { value: string };
          name?: { value: string };
          properties?: { name: string; value: { value: unknown } }[];
        }[];
      };
      const byId = new Map(nodes.map((node) => [node.nodeId, node]));
      const region = nodes.find((node) => node.role?.value === "region" && node.name?.value === "big.ts, 2,000 lines");
      expect(region).toBeDefined();
      const inRegion = (node: (typeof nodes)[number]) => {
        for (let at = node.parentId; at; at = byId.get(at)?.parentId) if (at === region!.nodeId) return true;
        return false;
      };
      const items = nodes.filter((node) => node.role?.value === "listitem" && inRegion(node));
      expect(items.length).toBe(dom.places.length);
      expect(byId.get(items[0]!.parentId!)?.role?.value).toBe("list");
      expect(await page.locator("[data-preview]").ariaSnapshot()).toContain(
        `listitem: const line${dom.places[0]! - 1} =`,
      );
    } finally {
      await page.close();
    }
  });

  test("code: drawn whole by Find's reveal, a highlighted read is the plain block it was: no region, no list", async () => {
    const page = await open("code", 2_000, 1);
    try {
      await painted(page);
      await frames(page, 3);
      const roles = await page.evaluate(() => {
        const box = document.querySelector<HTMLElement>("[data-preview]")!;
        const shadow = box.querySelector("diffs-container")!.shadowRoot!;
        return {
          box: box.getAttribute("role"),
          label: box.getAttribute("aria-label"),
          rows: shadow.querySelectorAll("[data-line][role]").length,
          list: shadow.querySelectorAll("[data-content][role]").length,
        };
      });
      expect(roles).toEqual({ box: null, label: null, rows: 0, list: 0 });
    } finally {
      await page.close();
    }
  });

  test("code: once a windowed read unmounts, nothing reachable from the page holds its virtualizer or its lines", async () => {
    const page = await open("code", 2_000);
    try {
      await painted(page);
      const before = await page.evaluate(() => {
        const scope = window as unknown as { __INSTANCE?: object; __refs?: Record<string, WeakRef<object>> };
        const host = document.querySelector("[data-preview] diffs-container")!;
        const instance = scope.__INSTANCE;
        scope.__refs = {
          host: new WeakRef(host),
          line: new WeakRef(host.shadowRoot!.querySelector("[data-line]")!),
          ...(instance ? { virtualizer: new WeakRef(instance) } : {}),
        };
        return { instance: instance !== undefined };
      });
      // Pierre's virtualizer names itself on the page while the read is drawn.
      expect(before.instance).toBe(true);
      await page.evaluate(() => (window as unknown as { __blockLines: { clear(): void } }).__blockLines.clear());
      await frames(page, 4);
      // The browser's own full collection (DOM and JS heaps), in tasks after the one that made the refs.
      const cdp = await page.context().newCDPSession(page);
      for (let round = 0; round < 2; round++) await cdp.send("HeapProfiler.collectGarbage");
      const after = await page.evaluate(() => {
        const scope = window as unknown as { __refs: Record<string, WeakRef<object>> };
        return {
          instance: "__INSTANCE" in window,
          toggle: "__TOGGLE" in window,
          alive: Object.entries(scope.__refs)
            .filter(([, ref]) => ref.deref() !== undefined)
            .map(([name]) => name),
        };
      });
      expect(after).toEqual({ instance: false, toggle: false, alive: [] });
    } finally {
      await page.close();
    }
  });

  test("code: a theme switch recolors the windowed lines and keeps the window", async () => {
    const page = await open("code", 2_000);
    try {
      await painted(page);
      const { dark, light, lines } = await page.evaluate(async () => {
        const shadow = document.querySelector("[data-preview] diffs-container")!.shadowRoot!;
        const frame = () => new Promise((done) => requestAnimationFrame(done));
        // Pierre's theme sheet in the shadow root, which names the theme type it draws in (the
        // harness's own colors are one set for both).
        const color = () => [...shadow.querySelectorAll("style")].map((style) => style.textContent).join("");
        const dark = color();
        document.documentElement.dataset.theme = "light";
        for (let index = 0; index < 4; index++) await frame();
        return { dark, light: color(), lines: shadow.querySelectorAll("[data-line]").length };
      });
      expect(light).not.toBe(dark);
      expect(lines).toBeLessThanOrEqual(32);
    } finally {
      await page.close();
    }
  });
});
