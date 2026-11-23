// cmux-web-test-timeout: 300
// l10n-allow-file: probe.
import { afterAll, beforeAll, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser, type Locator, type Page } from "playwright";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("thought-click-targets-browser.test.ts", async () => {
  const ENTRY = "agent-pane.thought-shapes";
  setDefaultTimeout(240_000);
  const { createServer } = await import("vite");
  const webviews = path.resolve(import.meta.dir, "..");
  let vite: Awaited<ReturnType<typeof createServer>> | undefined;
  let browser: Browser;
  beforeAll(async () => {
    vite = await createServer({
      configFile: path.join(webviews, "vite.config.gallery-dev.ts"),
      server: { port: 0, host: "127.0.0.1", strictPort: false },
      logLevel: "error",
    });
    await vite.listen();
    browser = await chromium.launch({ headless: true });
    await warmGalleryFrame(vite, [ENTRY], { browser });
  });
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });
  /** Two painted frames: what a click or hover changed has rendered and painted. */
  const twoFrames = (page: Page) =>
    page.evaluate(() => new Promise<void>((r) => requestAnimationFrame(() => requestAnimationFrame(() => r()))));
  /** Painted, and no finite transition or animation is still running (an expand, a hover tint). */
  const settle = async (page: Page) => {
    await twoFrames(page);
    await page.waitForFunction(
      () =>
        document
          .getAnimations()
          .every((a) => a.playState !== "running" || a.effect?.getComputedTiming().iterations === Infinity),
      undefined,
      { timeout: 10_000 },
    );
    await twoFrames(page);
  };
  /** The gallery frame mounted with its fonts and first rows painted. */
  const ready = async (page: Page) => {
    await page.evaluate(() => document.fonts.ready);
    await page.locator("button.cv-thought, button.cv-worked.is-toggle").first().waitFor({ state: "visible" });
    await settle(page);
  };
  /** Opens a collapsed toggle header and waits for it to read open and settle. */
  const expand = async (page: Page, toggle: Locator) => {
    if ((await toggle.count()) && (await toggle.getAttribute("aria-expanded")) !== "true") {
      await toggle.click();
      await page.waitForFunction((el) => el?.getAttribute("aria-expanded") === "true", await toggle.elementHandle());
      await settle(page);
    }
  };
  /** Waits (bounded) for `attr` to leave `before`; resolves either way, the caller reads the result. */
  const changeFrom = async (page: Page, button: Locator, before: string | null) => {
    const handle = await button.elementHandle();
    await page
      .waitForFunction(([el, was]) => el?.getAttribute("aria-expanded") !== was, [handle, before] as const, {
        timeout: 3_000,
      })
      .catch(() => undefined);
    await settle(page);
  };
  const SHAPES = ["short", "long", "lead-run", "between-calls", "working-settled"];
  for (const variant of SHAPES)
    test(`probe ${variant}`, async () => {
      const page = await browser.newPage({ viewport: { width: 900, height: 900 } });
      const port = (vite!.httpServer!.address() as { port: number }).port;
      for (;;) {
        await page.goto(
          `http://127.0.0.1:${port}${galleryFrame("agent-pane.thought-shapes", { variant, frame: "component", width: 900 })}`,
        );
        try {
          await page.waitForFunction(() => document.documentElement.dataset.galleryReady === "1", undefined, {
            timeout: 120_000,
          });
          break;
        } catch (error) {
          if (!/context was destroyed|navigat/i.test(String(error))) throw error;
        }
      }
      await ready(page);
      await expand(page, page.locator("button.cv-worked.is-toggle").last());
      await expand(page, page.locator(".cv-tools > .cv-tool.is-toggle").first());
      const total = await page.locator("button.cv-thought").count();
      const failures: string[] = [];
      let probes = 0;
      for (let n = 0; n < total; n += 1) {
        const button = page.locator("button.cv-thought").nth(n);
        const row = await button.locator("xpath=..").boundingBox();
        const first = (await button.boundingBox())!;
        // A thought is one line: a click anywhere along it, glyph to the row's end, toggles it.
        const xs: [string, number][] = [
          ["icon", first.x + 8],
          ["mid", first.x + first.width / 2],
          ["past-words", Math.min(first.x + first.width + 40, row!.x + row!.width - 2)],
          ["row-end", row!.x + row!.width - 2],
        ];
        for (const [name, x] of xs) {
          const b = (await button.boundingBox())!;
          const before = await button.getAttribute("aria-expanded");
          await page.mouse.click(x, b.y + Math.min(8, b.height / 2));
          await changeFrom(page, button, before);
          const after = await button.getAttribute("aria-expanded");
          probes += 1;
          if (after === before)
            failures.push(
              `${variant} #${n} @${name} (${Math.round(x - row!.x)}/${Math.round(row!.width)}): stayed ${before}`,
            );
          else {
            await page.mouse.click(first.x + 8, (await button.boundingBox())!.y + 8);
            await changeFrom(page, button, after);
          }
        }
      }
      console.log(
        `SWEEP ${variant}: ${total} thought buttons, ${probes} clicks, ${failures.length} swallowed\n  ${failures.join("\n  ")}`,
      );
      expect(total).toBeGreaterThan(0);
      expect(failures).toEqual([]);
    });

  // Real pointer gestures on a Thought row and on a tool-run row (the same kind of toggle header):
  // press, travel a few px, release; a double-click; a press on the words and one past them.
  // For each: was a selection made, did the Reply popover show, did the row toggle.
  const GESTURES: [string, number, number][] = [
    ["click", 0, 0],
    ["travel 1px", 1, 0],
    ["travel 2px", 2, 0],
    ["travel 3px", 3, 0],
    ["travel 5px", 5, 0],
    ["travel 8px", 8, 0],
    ["travel 40px", 40, 0],
  ];
  test("gestures on a Thought row toggle like the other toggle rows", async () => {
    const page = await browser.newPage({ viewport: { width: 900, height: 900 } });
    const port = (vite!.httpServer!.address() as { port: number }).port;
    for (;;) {
      await page.goto(
        `http://127.0.0.1:${port}${galleryFrame(ENTRY, { variant: "lead-run", frame: "component", width: 900 })}`,
      );
      try {
        await page.waitForFunction(() => document.documentElement.dataset.galleryReady === "1", undefined, {
          timeout: 120_000,
        });
        break;
      } catch (error) {
        if (!/context was destroyed|navigat/i.test(String(error))) throw error;
      }
    }
    await ready(page);
    await expand(page, page.locator("button.cv-worked.is-toggle").last());
    await expand(page, page.locator(".cv-tools > .cv-tool.is-toggle").first());
    const targets: [string, string][] = [
      ["thought", "button.cv-thought"],
      ["tool-run", ".cv-tools > .cv-tool.is-toggle"],
    ];
    const rows: string[] = [];
    const wrong: string[] = [];
    const probe = async (
      kind: string,
      selector: string,
      label: string,
      where: "words" | "past",
      gesture: () => Promise<void>,
    ) => {
      const button = page.locator(selector).first();
      const before = await button.getAttribute("aria-expanded");
      await page.evaluate(() => window.getSelection()?.removeAllRanges());
      await gesture();
      // A drag or double-click must not toggle: no condition to await, so let the gesture's
      // pointerup render and paint, and any toggle it started run out.
      await settle(page);
      const after = await button.getAttribute("aria-expanded");
      const info = await page.evaluate(() => ({
        selected: window.getSelection()?.toString().length ?? 0,
        popover: document.querySelectorAll(".cv-selection-reply").length,
      }));
      const toggled = before !== after;
      rows.push(
        `${kind.padEnd(8)} ${where.padEnd(5)} ${label.padEnd(12)} selection=${info.selected} popover=${info.popover} toggled=${toggled}`,
      );
      // a small travel is a click for both; a big one is a drag for both; the popover never shows over a header
      const expected =
        label === "double-click" ? false : label.startsWith("travel") ? Number(label.match(/\d+/)![0]) <= 4 : true;
      if (toggled !== expected) wrong.push(`${kind} ${where} ${label}: toggled=${toggled}, expected ${expected}`);
      if (info.popover > 0) wrong.push(`${kind} ${where} ${label}: reply popover over a toggle header`);
      if (toggled) {
        await page.evaluate(() => window.getSelection()?.removeAllRanges());
        await button.click({ position: { x: 8, y: 8 } });
        await changeFrom(page, button, after);
      }
    };
    for (const [kind, selector] of targets) {
      const b = (await page.locator(selector).first().boundingBox())!;
      const y = b.y + b.height / 2;
      const words = b.x + 30;
      const past = b.x + b.width - 40;
      for (const [where, x] of [
        ["words", words],
        ["past", past],
      ] as const) {
        for (const [label, dx] of GESTURES) {
          await probe(kind, selector, label, where, async () => {
            await page.mouse.move(x, y);
            await page.mouse.down();
            if (dx) await page.mouse.move(x + dx, y, { steps: 3 });
            await page.mouse.up();
          });
        }
        await probe(kind, selector, "double-click", where, async () => {
          await page.mouse.dblclick(x, y);
        });
      }
    }
    // A selection left in other text (a triple-click on the reply, which shows the Reply popover) does
    // not swallow the click on a header; nor does one inside an opened thought's body.
    for (const [kind, selector] of targets) {
      const button = page.locator(selector).first();
      const b = (await button.boundingBox())!;
      for (const [label, select] of [
        ["reply selected", () => page.locator(".selectable:not(.cv-thought__body)").first().click({ clickCount: 3 })],
        [
          "body selected",
          async () => {
            const body = page.locator(".cv-thought__body").first();
            if (await body.count()) await body.click({ clickCount: 3 });
          },
        ],
      ] as const) {
        const before = await button.getAttribute("aria-expanded");
        await select();
        await settle(page);
        const picked = await page.evaluate(() => ({
          n: window.getSelection()?.toString().length ?? 0,
          pop: document.querySelectorAll(".cv-selection-reply").length,
        }));
        await page.mouse.click(b.x + 30, (await button.boundingBox())!.y + b.height / 2);
        await changeFrom(page, button, before);
        const toggled = before !== (await button.getAttribute("aria-expanded"));
        rows.push(
          `${kind.padEnd(8)} ${label.padEnd(15)} selection=${picked.n} popover=${picked.pop} toggled=${toggled}`,
        );
        if (!toggled) wrong.push(`${kind} ${label}: click swallowed (selection=${picked.n})`);
        if (toggled) {
          await page.evaluate(() => window.getSelection()?.removeAllRanges());
          await button.click({ position: { x: 8, y: 8 } });
          await changeFrom(page, button, before === "true" ? "false" : "true");
        }
      }
    }
    console.log(`GESTURES\n  ${rows.join("\n  ")}\nWRONG: ${wrong.join("; ")}`);
    expect(rows.length).toBe(36);
    expect(wrong).toEqual([]);
  });

  // Leo, 2026-11-22: "the highlight of the thought thing needs to be highlighted when you're on the
  // line and not necessarily on the thought word, because we can collapse from anywhere on the line,
  // because that's good ergo. just like the rest of the tool calls." The button spans the row for
  // the click (above), and its words light from anywhere along it. (Before: only on its glyph, words
  // and chevron, Lucas 2026-11-06.)
  test("a Thought row's words light from anywhere on its line, as a tool row's do", async () => {
    const page = await browser.newPage({ viewport: { width: 900, height: 600 } });
    const port = (vite!.httpServer!.address() as { port: number }).port;
    for (;;) {
      await page.goto(
        `http://127.0.0.1:${port}${galleryFrame(ENTRY, { variant: "short", frame: "component", width: 900 })}`,
      );
      try {
        await page.waitForFunction(() => document.documentElement.dataset.galleryReady === "1", undefined, {
          timeout: 120_000,
        });
        break;
      } catch (error) {
        if (!/context was destroyed|navigat/i.test(String(error))) throw error;
      }
    }
    await ready(page);
    await expand(page, page.locator("button.cv-worked.is-toggle").last());
    const button = page.locator("button.cv-thought").first();
    const words = button.locator(".cv-tool__text");
    const b = (await button.boundingBox())!;
    const w = (await words.boundingBox())!;
    const color = () => words.evaluate((el) => getComputedStyle(el).color);
    const shoot = process.env.THOUGHT_HOVER_SHOTS;
    const clip = { x: b.x, y: Math.max(0, b.y - 12), width: Math.min(b.width, 600), height: b.height + 24 };
    await page.mouse.move(b.x + b.width / 2, b.y - 60);
    await settle(page);
    const rest = await color();
    if (shoot) await page.screenshot({ path: `${shoot}-rest.png`, clip });
    await page.mouse.move(w.x + 10, b.y + b.height / 2);
    await settle(page);
    const onWords = await color();
    if (shoot) await page.screenshot({ path: `${shoot}-hover-words.png`, clip });
    await page.mouse.move(Math.min(w.x + w.width + 120, b.x + b.width - 20), b.y + b.height / 2);
    await settle(page);
    const pastWords = await color();
    if (shoot) await page.screenshot({ path: `${shoot}-hover-past-words.png`, clip });
    console.log(
      `HOVER words ${Math.round(w.width)}px of ${Math.round(b.width)}px: rest=${rest} onWords=${onWords} pastWords=${pastWords}`,
    );
    expect(onWords).not.toBe(rest);
    expect(pastWords).toBe(onWords);
    // The same holds for the tool row under it, measured the same way.
    const tool = page.locator(".cv-tools > button.cv-tool:not(.cv-thought)").first();
    if (await tool.count()) {
      const t = (await tool.boundingBox())!;
      const toolWords = tool.locator(".cv-tool__text").first();
      const toolColor = () => toolWords.evaluate((el) => getComputedStyle(el).color);
      await page.mouse.move(t.x + t.width / 2, t.y - 80);
      await settle(page);
      const toolRest = await toolColor();
      await page.mouse.move(t.x + t.width - 20, t.y + t.height / 2);
      await settle(page);
      expect(await toolColor()).not.toBe(toolRest);
      expect(await toolColor()).toBe(onWords);
    }
  });

  // Leo, 2026-11-22: "had the whole line be the line? then you expand and it simply shows you the
  // rest. the brain, of course, stays." and "a morphing animation to and from thought": the row's
  // line is the thought's first line, opening swaps no word and moves none, the rest unfolds under
  // it, and a frame midway through shows the row between its two heights.
  for (const variant of ["short", "long", "wrapping-line"])
    test(`opening a thought keeps its line in place and unfolds the rest under it (${variant})`, async () => {
      const page = await browser.newPage({ viewport: { width: 900, height: 900 } });
      const port = (vite!.httpServer!.address() as { port: number }).port;
      for (;;) {
        await page.goto(`http://127.0.0.1:${port}${galleryFrame(ENTRY, { variant, frame: "component", width: 900 })}`);
        try {
          await page.waitForFunction(() => document.documentElement.dataset.galleryReady === "1", undefined, {
            timeout: 120_000,
          });
          break;
        } catch (error) {
          if (!/context was destroyed|navigat/i.test(String(error))) throw error;
        }
      }
      await ready(page);
      await expand(page, page.locator("button.cv-worked.is-toggle").last());
      const button = page.locator("button.cv-thought").first();
      /** The line's words, where its first letter is drawn, its height, and the brain and chevron. */
      const read = () =>
        button.evaluate((node) => {
          const line = node.querySelector<HTMLElement>(".cv-thought__preview")!;
          const range = document.createRange();
          range.setStart(line.firstChild!, 0);
          range.setEnd(line.firstChild!, 1);
          const letter = range.getBoundingClientRect();
          const body = node.nextElementSibling?.querySelector<HTMLElement>(".cv-thought__body");
          return {
            words: line.textContent ?? "",
            left: letter.left,
            top: letter.top,
            line: line.getBoundingClientRect().height,
            brain: node.querySelectorAll(".cv-tool__icon svg").length,
            label: node.querySelectorAll(".cv-thought__label").length,
            cut: line.scrollHeight > line.clientHeight + 1,
            // The fold sizes the body's wrapper, so the wrapper's height is what is drawn midway.
            body: body ? body.parentElement!.getBoundingClientRect().height : 0,
            rest: body?.textContent ?? "",
            below: body ? body.getBoundingClientRect().top >= letter.bottom - 1 : true,
          };
        });
      const closed = await read();
      expect(closed.brain).toBe(1);
      expect(closed.label).toBe(0);
      expect(closed.words.startsWith("Thought")).toBe(false);
      expect(closed.line).toBeLessThanOrEqual(22.5);
      // Midway: the same words in the same place, the row between its closed and open heights.
      const box = (await button.boundingBox())!;
      await page.mouse.click(box.x + box.width - 30, box.y + box.height / 2);
      await page.waitForFunction((el) => el?.getAttribute("aria-expanded") === "true", await button.elementHandle());
      const midway = await page.evaluate(() => {
        const moving = document
          .getAnimations()
          .filter((a) => a.playState === "running" && a.effect?.getComputedTiming().iterations !== Infinity);
        for (const animation of moving) {
          const timing = animation.effect!.getComputedTiming();
          animation.pause();
          animation.currentTime = Number(timing.duration) / 2;
        }
        return moving.length;
      });
      const mid = await read();
      await page.evaluate(() => document.getAnimations().forEach((a) => a.playState === "paused" && a.play()));
      await settle(page);
      const open = await read();
      for (const state of [mid, open]) {
        expect(state.words).toBe(closed.words);
        expect(Math.abs(state.left - closed.left)).toBeLessThanOrEqual(0.5);
        expect(Math.abs(state.top - closed.top)).toBeLessThanOrEqual(0.5);
        expect(state.brain).toBe(1);
        expect(state.label).toBe(0);
        expect(state.below).toBe(true);
      }
      expect(midway).toBeGreaterThan(0);
      const grew = open.line + open.body - closed.line;
      const part = mid.line + mid.body - closed.line;
      expect(grew).toBeGreaterThan(10);
      expect(part).toBeGreaterThan(0);
      expect(part).toBeLessThan(grew);
      expect(open.cut).toBe(false);
      if (variant === "wrapping-line") {
        // Nothing under the line: the line itself wraps open.
        expect(closed.cut).toBe(true);
        expect(open.rest).toBe("");
        expect(open.line).toBeGreaterThan(closed.line + 10);
      } else {
        expect(open.rest.length).toBeGreaterThan(0);
        expect(open.rest.includes(closed.words)).toBe(false);
      }
      console.log(
        `MORPH ${variant}: line ${closed.line}px -> ${mid.line}px -> ${open.line}px, body 0 -> ${Math.round(mid.body)}px -> ${Math.round(open.body)}px, first letter moved ${Math.abs(open.left - closed.left)}px, ${Math.abs(open.top - closed.top)}px`,
      );
      // Closing reverses it: one line again, cut where it was.
      await page.mouse.click(box.x + box.width - 30, box.y + 8);
      await page.waitForFunction((el) => el?.getAttribute("aria-expanded") === "false", await button.elementHandle());
      await settle(page);
      const again = await read();
      expect(again.words).toBe(closed.words);
      expect(again.line).toBe(closed.line);
      expect(again.cut).toBe(closed.cut);
      expect(Math.abs(again.top - closed.top)).toBeLessThanOrEqual(0.5);
      await page.close();
    });

  test("a thought its line holds whole draws no chevron and does not open", async () => {
    const page = await browser.newPage({ viewport: { width: 900, height: 900 } });
    const port = (vite!.httpServer!.address() as { port: number }).port;
    for (;;) {
      await page.goto(
        `http://127.0.0.1:${port}${galleryFrame(ENTRY, { variant: "one-line", frame: "component", width: 900 })}`,
      );
      try {
        await page.waitForFunction(() => document.documentElement.dataset.galleryReady === "1", undefined, {
          timeout: 120_000,
        });
        break;
      } catch (error) {
        if (!/context was destroyed|navigat/i.test(String(error))) throw error;
      }
    }
    await page.evaluate(() => document.fonts.ready);
    await expand(page, page.locator("button.cv-worked.is-toggle").last());
    const row = page.locator(".cv-thought.is-whole").first();
    await row.waitFor({ state: "visible" });
    expect(await page.locator("button.cv-thought").count()).toBe(0);
    expect(await row.locator(".cv-tool__chevron").count()).toBe(0);
    expect(await row.locator(".cv-tool__icon svg").count()).toBe(1);
    expect(await row.locator(".cv-thought__preview").textContent()).toBe(
      "Check the retry helper first, then the callers.",
    );
    expect(await row.locator(".cv-thought__time").textContent()).toBe("4s");
    await row.click();
    await settle(page);
    expect(await page.locator(".cv-thought__body").count()).toBe(0);
    await page.close();
  });
});
