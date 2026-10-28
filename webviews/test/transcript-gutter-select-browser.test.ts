// l10n-allow-file: test fixture prompts and replies, not shipped UI.
// A drag that starts in the empty margin beside the chat's column selects text, as a document's
// margins do (Leo 2026-10-21: "i want click and drag to highlight text even when im just clicking
// on the left or right of the main pane/out of the chat portion column"). Pressed beside the first
// message and dragged down into the third, the selection holds text from all three. As in a
// document, a press left of a line starts at its start and one right of it at its end. A plain click
// in the margin selects nothing and takes focus off the composer as a press on the background always
// has; a drag inside the column selects as it always did. On base the margin drag selected nothing.
//
// Real Chromium and WebKit from Playwright; CI fails the file when it cannot launch (requireBrowserLane).
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, webkit, type Browser, type BrowserType, type Page } from "playwright";
import { installPaintedFrames } from "./support/paintedFrames";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { warmViteServer } from "./support/warmDevServer";

await requireBrowserLane("transcript-gutter-select-browser.test.ts", async () => {
  setDefaultTimeout(120_000);
  const engines: [string, BrowserType][] = [];
  for (const engine of [
    ["chromium", chromium],
    ["webkit", webkit],
  ] as [string, BrowserType][]) {
    try {
      await (await engine[1].launch({ headless: true })).close();
      engines.push(engine);
    } catch {
      console.warn(`transcript-gutter-select: skipping ${engine[0]} (run \`bunx playwright install ${engine[0]}\`)`);
    }
  }
  if (engines.length === 0) {
    describe.skip("gutter select", () => test("no engine", () => {}));
    return;
  }
  const { createServer } = await import("vite");
  const webviews = path.resolve(import.meta.dir, "..");
  let vite: Awaited<ReturnType<typeof createServer>> | undefined;
  const browsers = new Map<string, Browser>();
  beforeAll(async () => {
    vite = await createServer({
      root: webviews,
      configFile: path.join(webviews, "vite.config.ts"),
      server: { port: 0, host: "127.0.0.1", strictPort: false },
      logLevel: "error",
    });
    await vite.listen();
    await warmViteServer(vite, "/test/browser/transcript-follow.html");
    for (const [name, type] of engines) browsers.set(name, await type.launch({ headless: true }));
  });
  afterAll(async () => {
    for (const browser of browsers.values()) await browser.close();
    await vite?.close();
  });

  let at = 0;
  const row = (id: string, kind: string, text: string) => ({ id, kind, text, version: 1, at: (at += 1_000) });
  // Three answers, each a paragraph a few lines long, so the column's text has lines beside the press.
  const rows = [
    row(
      "m1",
      "assistant",
      "Alpha keeper. The keeper climbed to the gallery and wiped the salt from the lantern glass.",
    ),
    row("m2", "assistant", "Bravo tide. The tide came in under the jetty and lifted the moored boats one by one."),
    row("m3", "assistant", "Charlie gull. A gull settled on the rail and watched the light sweep across the water."),
  ];

  const open = async (name: string): Promise<Page> => {
    const page = await browsers.get(name)!.newPage({ viewport: { width: 1280, height: 640 } });
    await installPaintedFrames(page);
    const { port } = vite!.httpServer!.address() as { port: number };
    await page.goto(`http://127.0.0.1:${port}/test/browser/transcript-follow.html`);
    await page.waitForFunction(() => "__showRows" in window);
    await page.evaluate((shown) => (window as unknown as { __showRows(rows: unknown): void }).__showRows(shown), rows);
    await rowsIn(page);
    await page.evaluate(async () => {
      for (let left = 10; left > 0; left--) await window.cmuxPaintFrame();
    });
    return page;
  };
  /// The client box of message `id`'s text, and the column's left and right edges.
  const box = (page: Page, id: string) =>
    page.evaluate((rowId) => {
      const node = document.querySelector<HTMLElement>(`.acpmux-row[data-row-id="${rowId}"]`)!;
      const text = node.querySelector<HTMLElement>(".cv-md") ?? node;
      const rect = text.getBoundingClientRect();
      const column = node.getBoundingClientRect();
      return { top: rect.top, bottom: rect.bottom, left: column.left, right: column.right };
    }, id);
  /// Waits for the transcript to draw rows (`prefix`'s, when given): React commits the shown rows after
  /// the harness call returns, so the scroller may not be in the page yet.
  const rowsIn = (page: Page, prefix = "") =>
    page.waitForSelector(`.acpmux-scroll .acpmux-row${prefix ? `[data-row-id^="${prefix}"]` : "[data-row-id]"}`, {
      state: "attached",
    });
  const selected = (page: Page) => page.evaluate(() => window.getSelection()?.toString() ?? "");

  /// Presses at `from`, drags to `to` in six moves a painted frame apart (as a hand drags), lifts.
  const drag = async (page: Page, from: { x: number; y: number }, to: { x: number; y: number }) => {
    await page.mouse.move(from.x, from.y);
    await page.mouse.down();
    for (let step = 1; step <= 6; step += 1) {
      await page.mouse.move(from.x + ((to.x - from.x) * step) / 6, from.y + ((to.y - from.y) * step) / 6);
      await page.evaluate(() => window.cmuxPaintFrame());
    }
    await page.mouse.up();
  };

  for (const [name] of engines) {
    test(`${name}: a drag from the left margin beside message 1 down into message 3 selects all three`, async () => {
      const page = await open(name);
      const first = await box(page, "m1");
      const third = await box(page, "m3");
      expect(first.left).toBeGreaterThan(100);
      await drag(page, { x: first.left / 2, y: first.top + 4 }, { x: third.left + 300, y: third.bottom - 4 });
      const text = await selected(page);
      // From the start of the line beside the press, as a document's margin selects.
      expect(text.startsWith("Alpha keeper.")).toBe(true);
      expect(text).toContain("Bravo tide. The tide came in under the jetty");
      expect(text).toContain("Charlie gull.");
      await page.close();
    });

    test(`${name}: the selection keeps its start when the text under the press is redrawn mid-drag`, async () => {
      const page = await open(name);
      const first = await box(page, "m1");
      const third = await box(page, "m3");
      const x = first.left / 2;
      await page.mouse.move(x, first.top + 4);
      await page.mouse.down();
      await page.mouse.move(x, first.top + 14);
      await page.evaluate(() => window.cmuxPaintFrame());
      // The reply redraws its first message: the text node under the press is replaced.
      const redrawn = [
        { ...rows[0], text: `**Alpha keeper.** ${rows[0]!.text.slice(14)}`, version: 2 },
        ...rows.slice(1),
      ];
      await page.evaluate(
        (shown) => (window as unknown as { __showRows(rows: unknown): void }).__showRows(shown),
        redrawn,
      );
      await page.evaluate(async () => {
        for (let left = 3; left > 0; left--) await window.cmuxPaintFrame();
      });
      expect(await page.evaluate(() => !!document.querySelector('.acpmux-row[data-row-id="m1"] strong'))).toBe(true);
      for (let step = 1; step <= 4; step += 1) {
        await page.mouse.move(
          x + ((third.left + 300 - x) * step) / 4,
          first.top + 14 + ((third.bottom - 18 - first.top) * step) / 4,
        );
        await page.evaluate(() => window.cmuxPaintFrame());
      }
      await page.mouse.up();
      const text = await selected(page);
      expect(text.startsWith("Alpha keeper.")).toBe(true);
      expect(text).toContain("Charlie gull.");
      await page.close();
    });

    test(`${name}: a drag whose message is taken out mid-drag ends, and selects nothing elsewhere`, async () => {
      const page = await open(name);
      const first = await box(page, "m1");
      const third = await box(page, "m3");
      const x = first.left / 2;
      await page.mouse.move(x, first.top + 4);
      await page.mouse.down();
      await page.mouse.move(x, first.top + 14);
      await page.evaluate(() => window.cmuxPaintFrame());
      // The first message leaves the transcript while the button is held.
      await page.evaluate(
        (shown) => (window as unknown as { __showRows(rows: unknown): void }).__showRows(shown),
        rows.slice(1),
      );
      await page.evaluate(async () => {
        for (let left = 3; left > 0; left--) await window.cmuxPaintFrame();
      });
      expect(await page.evaluate(() => !!document.querySelector('.acpmux-row[data-row-id="m1"]'))).toBe(false);
      for (let step = 1; step <= 4; step += 1) {
        await page.mouse.move(
          x + ((third.left + 300 - x) * step) / 4,
          first.top + 14 + ((third.bottom - 18 - first.top) * step) / 4,
        );
        await page.evaluate(() => window.cmuxPaintFrame());
      }
      await page.mouse.up();
      expect(await selected(page)).not.toContain("Bravo");
      await page.close();
    });

    for (const [removed, kept] of [
      ["m1", ["m2", "m3"]],
      ["m3", ["m1", "m2"]],
    ] as const) {
      test(`${name}: a finished margin selection is cleared when its ${removed === "m1" ? "start" : "end"} message is taken out`, async () => {
        const page = await open(name);
        const first = await box(page, "m1");
        const third = await box(page, "m3");
        await drag(page, { x: first.left / 2, y: first.top + 4 }, { x: third.left + 300, y: third.bottom - 4 });
        expect(await selected(page)).toContain("Bravo");
        await page.evaluate(
          (shown) => (window as unknown as { __showRows(rows: unknown): void }).__showRows(shown),
          rows.filter((each) => kept.includes(each.id as never)),
        );
        await page.evaluate(async () => {
          for (let left = 3; left > 0; left--) await window.cmuxPaintFrame();
        });
        expect(await page.evaluate((id) => !!document.querySelector(`.acpmux-row[data-row-id="${id}"]`), removed)).toBe(
          false,
        );
        expect(await selected(page)).toBe("");
        await page.close();
      });
    }

    test(`${name}: a selection whose end moves to another message (Shift-click) is kept when the old end row goes`, async () => {
      const page = await open(name);
      const first = await box(page, "m1");
      const second = await box(page, "m2");
      await drag(page, { x: first.left / 2, y: first.top + 4 }, { x: second.left + 300, y: second.top + 4 });
      expect(await selected(page)).toContain("Bravo");
      // The end moves into the third message, as a Shift-click there does.
      await page.evaluate(() => {
        const text = document.querySelector('.acpmux-row[data-row-id="m3"] .cv-md')!;
        const walker = document.createTreeWalker(text, NodeFilter.SHOW_TEXT);
        const node = walker.nextNode()!;
        window.getSelection()!.extend(node, 7);
      });
      await page.evaluate(async () => {
        for (let left = 2; left > 0; left--) await window.cmuxPaintFrame();
      });
      expect(await selected(page)).toContain("Charlie");
      // The second message goes: the selection the reader made from the first into the third stays.
      await page.evaluate(
        (shown) => (window as unknown as { __showRows(rows: unknown): void }).__showRows(shown),
        rows.filter((each) => each.id !== "m2"),
      );
      await page.evaluate(async () => {
        for (let left = 3; left > 0; left--) await window.cmuxPaintFrame();
      });
      const text = await selected(page);
      expect(text.startsWith("Alpha keeper.")).toBe(true);
      expect(text).toContain("Charlie");
      await page.close();
    });

    test(`${name}: a drag that stays in the left margin selects whole lines up to the line beside the pointer`, async () => {
      const page = await open(name);
      const first = await box(page, "m1");
      const third = await box(page, "m3");
      await drag(page, { x: first.left / 2, y: first.top + 4 }, { x: first.left / 2, y: third.bottom - 4 });
      const text = await selected(page);
      expect(text).toContain("Alpha keeper.");
      expect(text).toContain("lifted the moored boats one by one.");
      expect(text).not.toContain("Charlie");
      await page.close();
    });

    test(`${name}: a drag from the right margin beside message 3 up into message 1 selects from the end of that line`, async () => {
      const page = await open(name);
      const first = await box(page, "m1");
      const third = await box(page, "m3");
      const x = (third.right + 1280 - 16) / 2;
      await drag(page, { x, y: third.bottom - 4 }, { x: first.left + 300, y: first.top + 4 });
      const text = await selected(page);
      expect(text).not.toContain("Alpha keeper.");
      expect(text).toContain("lantern glass.");
      expect(text).toContain("Bravo tide.");
      expect(text.trimEnd().endsWith("sweep across the water.")).toBe(true);
      await page.close();
    });

    test(`${name}: a click in the margin selects nothing and takes focus off the composer, as before`, async () => {
      const page = await open(name);
      // A field outside the transcript holds focus, as the composer does. Fixed, so it moves nothing.
      await page.evaluate(() => {
        const field = document.createElement("textarea");
        field.id = "composer-stand-in";
        Object.assign(field.style, { position: "fixed", left: "0", bottom: "0", width: "40px", height: "20px" });
        document.body.append(field);
        field.focus();
      });
      const first = await box(page, "m1");
      await page.mouse.click(first.left / 2, first.top + 4);
      await page.evaluate(() => window.cmuxPaintFrame());
      expect(await selected(page)).toBe("");
      // A press on the background leaves the composer (Leo 2026-10-20, composerFocus.ts), as on base.
      expect(await page.evaluate(() => document.activeElement === document.body)).toBe(true);
      await page.close();
    });

    test(`${name}: a click in the margin away from any text also takes focus off the composer`, async () => {
      const page = await open(name);
      const first = await box(page, "m1");
      const third = await box(page, "m3");
      const view = await page.evaluate(() => {
        const rect = document.querySelector<HTMLElement>(".acpmux-scroll")!.getBoundingClientRect();
        return { top: rect.top, bottom: rect.bottom };
      });
      // Above the first answer and below the last, where no line sits beside the press.
      const points = [first.top - 12, third.bottom + 24].filter((y) => y > view.top + 2 && y < view.bottom - 2);
      expect(points.length).toBeGreaterThan(0);
      for (const y of points) {
        await page.evaluate(() => {
          document.getElementById("composer-stand-in")?.remove();
          const field = document.createElement("textarea");
          field.id = "composer-stand-in";
          Object.assign(field.style, { position: "fixed", left: "0", bottom: "0", width: "40px", height: "20px" });
          document.body.append(field);
          field.focus();
        });
        await page.mouse.click(first.left / 2, y);
        await page.evaluate(() => window.cmuxPaintFrame());
        expect(await selected(page)).toBe("");
        expect(await page.evaluate(() => document.activeElement === document.body)).toBe(true);
      }
      await page.close();
    });

    test(`${name}: a click in the margin lets go of a selection in the transcript`, async () => {
      const page = await open(name);
      const first = await box(page, "m1");
      const third = await box(page, "m3");
      await drag(page, { x: first.left / 2, y: first.top + 4 }, { x: first.left / 2, y: third.top + 4 });
      expect(await selected(page)).toContain("Bravo");
      await page.mouse.click(first.left / 2, third.top + 4);
      expect(await selected(page)).toBe("");
      await page.close();
    });

    test(`${name}: the selection follows the view as it scrolls under a still pointer`, async () => {
      const page = await browsers.get(name)!.newPage({ viewport: { width: 1280, height: 360 } });
      await installPaintedFrames(page);
      const { port } = vite!.httpServer!.address() as { port: number };
      await page.goto(`http://127.0.0.1:${port}/test/browser/transcript-follow.html`);
      await page.waitForFunction(() => "__showRows" in window);
      const long = Array.from({ length: 12 }, (_, index) =>
        row(`l${index}`, "assistant", `Line ${index}. The keeper wrote the hour and the height of the tide.`),
      );
      await page.evaluate(
        (shown) => (window as unknown as { __showRows(rows: unknown): void }).__showRows(shown),
        long,
      );
      await rowsIn(page);
      await page.evaluate(async () => {
        const scroller = document.querySelector<HTMLElement>(".acpmux-scroll")!;
        for (let left = 10; left > 0; left--) await window.cmuxPaintFrame();
        scroller.scrollTop = 0;
        for (let left = 4; left > 0; left--) await window.cmuxPaintFrame();
      });
      const top = await box(page, "l0");
      const x = top.left / 2;
      await page.mouse.move(x, top.top + 4);
      await page.mouse.down();
      await page.mouse.move(x, 300);
      await page.evaluate(() => window.cmuxPaintFrame());
      const before = await selected(page);
      // The wheel moves the view; the pointer does not move.
      await page.evaluate(async () => {
        document.querySelector<HTMLElement>(".acpmux-scroll")!.scrollTop += 200;
        for (let left = 3; left > 0; left--) await window.cmuxPaintFrame();
      });
      const after = await selected(page);
      await page.mouse.up();
      expect(after.length).toBeGreaterThan(before.length);
      expect(after.startsWith("Line 0.")).toBe(true);
      await page.close();
    });

    test(`${name}: the selection keeps its start when the view scrolls its row far out, until it is cleared (virtualized)`, async () => {
      const page = await browsers.get(name)!.newPage({ viewport: { width: 1280, height: 360 } });
      await installPaintedFrames(page);
      const { port } = vite!.httpServer!.address() as { port: number };
      await page.goto(`http://127.0.0.1:${port}/test/browser/transcript-follow.html`);
      await page.waitForFunction(() => "__showRows" in window);
      const long = Array.from({ length: 120 }, (_, index) =>
        row(`v${index}`, "assistant", `Entry ${index}. The keeper wrote the hour and the height of the tide.`),
      );
      await page.evaluate(
        (shown) => (window as unknown as { __showRows(rows: unknown): void }).__showRows(shown),
        long,
      );
      await rowsIn(page);
      await page.evaluate(async () => {
        const scroller = document.querySelector<HTMLElement>(".acpmux-scroll")!;
        for (let left = 10; left > 0; left--) await window.cmuxPaintFrame();
        scroller.scrollTop = 0;
        for (let left = 6; left > 0; left--) await window.cmuxPaintFrame();
      });
      const top = await box(page, "v0");
      const x = top.left / 2;
      await page.mouse.move(x, top.top + 4);
      await page.mouse.down();
      await page.mouse.move(x, 200);
      await page.evaluate(() => window.cmuxPaintFrame());
      // The view moves many viewports down under the held drag, past the rows it keeps mounted.
      const unmountedOnBase = await page.evaluate(async () => {
        const scroller = document.querySelector<HTMLElement>(".acpmux-scroll")!;
        for (let step = 0; step < 12; step += 1) {
          scroller.scrollTop += 400;
          for (let left = 3; left > 0; left--) await window.cmuxPaintFrame();
        }
        return scroller.scrollTop;
      });
      expect(unmountedOnBase).toBeGreaterThan(3000);
      await page.mouse.move(x, 210);
      await page.evaluate(() => window.cmuxPaintFrame());
      await page.mouse.up();
      const paint = () =>
        page.evaluate(async () => {
          for (let left = 4; left > 0; left--) await window.cmuxPaintFrame();
        });
      await paint();
      const mounted = () => page.evaluate(() => !!document.querySelector('.acpmux-row[data-row-id="v0"]'));
      // The selection still starts at the press after the button lifts, and ends in view. (The rows
      // between stay unmounted, as for any selection in this virtualized transcript.)
      const text = await selected(page);
      expect(text.startsWith("Entry 0.")).toBe(true);
      expect(text).toMatch(/Entry 11\d\./);
      expect(await mounted()).toBe(true);
      // A click in the margin clears it, and the held row goes back to being virtualized.
      await page.mouse.click(x, 210);
      await paint();
      expect(await selected(page)).toBe("");
      expect(await mounted()).toBe(false);
      await page.close();
    });

    test(`${name}: showing another chat lets the held rows go`, async () => {
      const page = await browsers.get(name)!.newPage({ viewport: { width: 1280, height: 360 } });
      await installPaintedFrames(page);
      const { port } = vite!.httpServer!.address() as { port: number };
      await page.goto(`http://127.0.0.1:${port}/test/browser/transcript-follow.html`);
      await page.waitForFunction(() => "__showSession" in window);
      const chat = (prefix: string) =>
        Array.from({ length: 120 }, (_, index) =>
          row(
            `${prefix}${index}`,
            "assistant",
            `Entry ${index}. The keeper wrote the hour and the height of the tide.`,
          ),
        );
      const first = chat("s");
      const showSession = (id: string, shown: unknown) =>
        page.evaluate(
          ([sessionId, list]) =>
            (window as unknown as { __showSession(id: string, rows: unknown): void }).__showSession(
              sessionId as string,
              list,
            ),
          [id, shown] as const,
        );
      const paint = (count: number) =>
        page.evaluate(async (n) => {
          for (let left = n; left > 0; left--) await window.cmuxPaintFrame();
        }, count);
      await showSession("session-1", first);
      await rowsIn(page, "s");
      await paint(10);
      await page.evaluate(() => (document.querySelector<HTMLElement>(".acpmux-scroll")!.scrollTop = 0));
      await paint(6);
      const top = await box(page, "s0");
      const x = top.left / 2;
      await page.mouse.move(x, top.top + 4);
      await page.mouse.down();
      await page.mouse.move(x, 200);
      await paint(1);
      await page.evaluate(async () => {
        const scroller = document.querySelector<HTMLElement>(".acpmux-scroll")!;
        for (let step = 0; step < 12; step += 1) {
          scroller.scrollTop += 400;
          for (let left = 3; left > 0; left--) await window.cmuxPaintFrame();
        }
      });
      await page.mouse.move(x, 210);
      await paint(1);
      await page.mouse.up();
      await paint(4);
      const mounted = () => page.evaluate(() => !!document.querySelector('.acpmux-row[data-row-id="s0"]'));
      expect(await mounted()).toBe(true);
      // Another chat, then back: the first chat's held row is virtualized again.
      await showSession("session-2", chat("t"));
      await rowsIn(page, "t");
      await paint(6);
      await showSession("session-1", first);
      await rowsIn(page, "s");
      await paint(6);
      await page.evaluate(() => (document.querySelector<HTMLElement>(".acpmux-scroll")!.scrollTop = 1e6));
      await paint(6);
      expect(await mounted()).toBe(false);
      await page.close();
    });

    test(`${name}: a held row stays mounted when older history pages in above it`, async () => {
      const page = await browsers.get(name)!.newPage({ viewport: { width: 1280, height: 360 } });
      await installPaintedFrames(page);
      const { port } = vite!.httpServer!.address() as { port: number };
      await page.goto(`http://127.0.0.1:${port}/test/browser/transcript-follow.html`);
      await page.waitForFunction(() => "__showRows" in window);
      const entry = (id: string, index: number) =>
        row(id, "assistant", `Entry ${index}. The keeper wrote the hour and the height of the tide.`);
      const tail = Array.from({ length: 120 }, (_, index) => entry(`p${index}`, index));
      const show = (shown: unknown) =>
        page.evaluate((list) => (window as unknown as { __showRows(rows: unknown): void }).__showRows(list), shown);
      const paint = (count: number) =>
        page.evaluate(async (n) => {
          for (let left = n; left > 0; left--) await window.cmuxPaintFrame();
        }, count);
      await show(tail);
      await rowsIn(page);
      await paint(10);
      await page.evaluate(() => (document.querySelector<HTMLElement>(".acpmux-scroll")!.scrollTop = 0));
      await paint(6);
      const top = await box(page, "p0");
      const x = top.left / 2;
      await page.mouse.move(x, top.top + 4);
      await page.mouse.down();
      await page.mouse.move(x, 200);
      await paint(1);
      await page.evaluate(async () => {
        const scroller = document.querySelector<HTMLElement>(".acpmux-scroll")!;
        for (let step = 0; step < 12; step += 1) {
          scroller.scrollTop += 400;
          for (let left = 3; left > 0; left--) await window.cmuxPaintFrame();
        }
      });
      const older = (count: number, from: number) =>
        Array.from({ length: count }, (_, index) => entry(`o${from + index}`, 1000 + from + index));
      const held = () => page.evaluate(() => !!document.querySelector('.acpmux-row[data-row-id="p0"]'));
      // Thirty older rows page in above: every row's index moves.
      await show([...older(30, 0), ...tail]);
      await paint(6);
      expect(await held()).toBe(true);
      // Rows arrive at both ends in one snapshot: neither its index nor its distance from the end holds.
      const newer = Array.from({ length: 5 }, (_, index) => entry(`n${index}`, 2000 + index));
      await show([...older(20, 30), ...older(30, 0), ...tail, ...newer]);
      await paint(6);
      expect(await held()).toBe(true);
      await page.mouse.move(x, 210);
      await paint(1);
      await page.mouse.up();
      await paint(4);
      expect((await selected(page)).startsWith("Entry 0.")).toBe(true);
      await page.close();
    });

    test(`${name}: a drag inside the column still selects as before`, async () => {
      const page = await open(name);
      const first = await box(page, "m1");
      const second = await box(page, "m2");
      await page.mouse.move(first.left + 4, first.top + 4);
      await page.mouse.down();
      await page.mouse.move(first.left + 40, first.top + 10);
      await page.mouse.move(first.left + 200, second.top + 4);
      await page.mouse.up();
      const text = await selected(page);
      expect(text).toContain("keeper");
      expect(text).toContain("Bravo");
      await page.close();
    });
  }
});
