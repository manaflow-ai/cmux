// l10n-allow-file: test fixture prompts, answers and tool titles, not shipped UI.
// Opening or closing a tool call, or a turn's "Worked for", never moves the reader's view (Leo
// 2026-10-20), in a real layout: while the view follows a streaming reply, the clicked line stays
// on the pixel it was clicked at through every frame of its fold, and the reply streaming on below
// does not pull it away. The fold plays (a height animation on `.cv-fold`) except under Reduce Motion.
//
// Real Chromium from Playwright; CI fails the file when it cannot launch (requireBrowserLane).
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser, type Page } from "playwright";
import { installPaintedFrames } from "./support/paintedFrames";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { warmViteServer } from "./support/warmDevServer";

await requireBrowserLane("transcript-fold-anchor-browser.test.ts", async () => {
  setDefaultTimeout(120_000);
  try {
    await (await chromium.launch({ headless: true })).close();
  } catch {
    console.warn("transcript-fold-anchor-browser: skipping (run `bunx playwright install chromium`)");
    describe.skip("transcript fold anchor", () => test("chromium", () => {}));
    return;
  }
  const { createServer } = await import("vite");
  const webviews = path.resolve(import.meta.dir, "..");
  let vite: Awaited<ReturnType<typeof createServer>> | undefined;
  let browser: Browser | undefined;
  beforeAll(async () => {
    vite = await createServer({
      root: webviews,
      configFile: path.join(webviews, "vite.config.ts"),
      server: { port: 0, host: "127.0.0.1", strictPort: false },
      logLevel: "error",
    });
    await vite.listen();
    await warmViteServer(vite, "/test/browser/transcript-follow.html");
    browser = await chromium.launch({ headless: true });
  });
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });

  type Row = { id: string; kind: string; text?: string; version: number; at: number; [key: string]: unknown };
  let at = 0;
  const row = (id: string, kind: string, text?: string, extra: Record<string, unknown> = {}): Row => ({
    id,
    kind,
    text,
    version: 1,
    at: (at += 1_000),
    ...extra,
  });
  const output = (lines: number) =>
    Array.from({ length: lines }, (_, index) => `line ${index + 1}: the keeper trimmed the wick`).join("\n");
  const read = (id: string, lines = 30) => ({
    kind: "tool",
    text: "",
    tool: { id, title: `Read src/${id}.ts`, kind: "read", status: "completed", output: output(lines) },
  });
  const paragraphs = (count: number) =>
    Array.from(
      { length: count },
      (_, index) =>
        `Paragraph ${index}. The keeper climbed to the gallery and wiped the salt from the lantern glass, ` +
        "then watched the light sweep the water for a while before going back down.",
    ).join("\n\n");
  /// A finished turn that worked first: its "Worked for" line opens to the calls.
  const turn = (index: number): Row[] => [
    row(`t${index}-user`, "user", `Question ${index}`),
    row(`t${index}-run`, "activity", undefined, { items: [read(`t${index}-a`), read(`t${index}-b`)] }),
    row(`t${index}-answer`, "assistant", paragraphs(2)),
    row(`t${index}-end`, "turnSummary", undefined, { status: "completed", durationMs: 9_000, toolCount: 2 }),
  ];
  const done = Array.from({ length: 8 }, (_, index) => turn(index)).flat();
  /// The turn still running: a call with output, then the reply streaming under it.
  const live = (version: number): Row[] => [
    row("live-user", "user", "Read the lantern log and summarize it."),
    row("live-run", "activity", undefined, { items: [read("live-log", 40)] }),
    row("live-answer", "assistant", paragraphs(version), { version, streaming: true }),
  ];

  const show = (page: Page, rows: Row[]) =>
    page.evaluate((shown) => (window as unknown as { __showRows(rows: unknown): void }).__showRows(shown), rows);
  /// Resolves once the view is at rest: no glide or fold running, and three painted frames in a row
  /// show the transcript scrolled and sized as the frame before.
  const settle = (page: Page) =>
    page.evaluate(
      () =>
        new Promise<void>((done, fail) => {
          let last = "";
          let alike = 0;
          const deadline = performance.now() + 10_000;
          window.cmuxAfterPaint(() => {
            const scroller = document.querySelector<HTMLElement>(".acpmux-scroll");
            if (!scroller) return;
            const moving = scroller
              .getAnimations({ subtree: true })
              .some(
                (animation) =>
                  animation.playState === "running" && animation.effect?.getTiming().iterations !== Infinity,
              );
            const now = `${Math.round(scroller.scrollTop)} ${scroller.scrollHeight} ${scroller.clientHeight}`;
            alike = !moving && now === last ? alike + 1 : 0;
            last = now;
            if (alike >= 3) {
              done();
              return false;
            }
            if (performance.now() > deadline) {
              fail(new Error(`the view did not come to rest in 10 s (moving: ${moving})`));
              return false;
            }
          });
        }),
    );
  const atLatest = (page: Page) =>
    page.evaluate(() => {
      const node = document.querySelector<HTMLElement>(".acpmux-scroll")!;
      return node.scrollHeight - node.clientHeight - node.scrollTop <= 2;
    });
  /// Marks the line `selector` finds last in the transcript, and returns where it is drawn.
  const probe = (page: Page, selector: string) =>
    page.evaluate((query) => {
      const lines = [...document.querySelectorAll<HTMLElement>(query)];
      const line = lines.at(-1)!;
      line.dataset.probe = "true";
      const box = line.getBoundingClientRect();
      return { top: box.top, x: box.left + 24, y: box.top + box.height / 2 };
    }, selector);
  /// Clicks the marked line, then follows it every painted frame for `ms`: how far it ever moved, and
  /// whether a fold was playing at some frame.
  const clickAndWatch = async (page: Page, ms = 450, at?: { x: number; y: number }) => {
    const point = await page.evaluate(() => {
      const box = document.querySelector<HTMLElement>("[data-probe]")!.getBoundingClientRect();
      return { x: box.left + 24, y: box.top + box.height / 2, top: box.top };
    });
    const watching = page.evaluate(
      ({ duration, from }) =>
        new Promise<{ moved: number; folded: boolean; stacked: number }>((resolve) => {
          const start = performance.now();
          let moved = 0;
          let folded = false;
          let stacked = 0;
          window.cmuxAfterPaint(() => {
            const line = document.querySelector<HTMLElement>("[data-probe]");
            if (line) moved = Math.max(moved, Math.abs(line.getBoundingClientRect().top - from));
            for (const fold of document.querySelectorAll(".cv-fold"))
              if (fold.getAnimations().length > 0) folded = true;
            const each = new Map<unknown, number>();
            for (const animation of document.getAnimations())
              if (animation.playState === "running" && animation.effect?.getTiming().iterations !== Infinity) {
                const target = (animation.effect as KeyframeEffect | null)?.target;
                each.set(target, (each.get(target) ?? 0) + 1);
              }
            stacked = Math.max(stacked, ...each.values(), 0);
            if (performance.now() - start < duration) return;
            resolve({ moved, folded, stacked });
            return false;
          });
        }),
      { duration: ms, from: point.top },
    );
    await page.mouse.click((at ?? point).x, (at ?? point).y);
    return { ...(await watching), top: point.top };
  };
  const probedTop = (page: Page) =>
    page.evaluate(() => document.querySelector<HTMLElement>("[data-probe]")!.getBoundingClientRect().top);
  const open = async (reducedMotion: "reduce" | "no-preference") => {
    const { port } = vite!.httpServer!.address() as { port: number };
    const page = await browser!.newPage({ viewport: { width: 900, height: 600 } });
    await installPaintedFrames(page);
    await page.emulateMedia({ reducedMotion });
    await page.goto(`http://127.0.0.1:${port}/test/browser/transcript-follow.html`);
    await page.waitForFunction(() => "__showRows" in window);
    return page;
  };

  test("a tool call opened while the reply is followed stays on its pixel, and the reply streaming on leaves it there", async () => {
    const page = await open("no-preference");
    await show(page, [...done, ...live(1)]);
    await settle(page);
    expect(await atLatest(page)).toBe(true);
    await probe(page, `[data-row-id="live-run"] button.cv-tool.is-toggle[aria-expanded="false"]`);

    const opened = await clickAndWatch(page);
    expect(await page.locator("[data-probe]").getAttribute("aria-expanded")).toBe("true");
    expect(opened.folded).toBe(true);
    expect(opened.moved).toBeLessThanOrEqual(1);
    // The output opened below the line, out past the view's end: the view stopped following.
    expect(await atLatest(page)).toBe(false);

    // The reply streams on; the reader's place holds.
    for (let version = 2; version < 6; version += 1) {
      await show(page, [...done, ...live(version)]);
      await settle(page);
    }
    expect(Math.abs((await probedTop(page)) - opened.top)).toBeLessThanOrEqual(1);

    // Closed again, away from the end, it stays where it is too.
    const closed = await clickAndWatch(page);
    expect(await page.locator("[data-probe]").getAttribute("aria-expanded")).toBe("false");
    expect(closed.moved).toBeLessThanOrEqual(1);
    await page.close();
  });

  test("a finished turn's Worked for opened at the latest row stays on its pixel", async () => {
    const page = await open("no-preference");
    await show(page, done);
    await settle(page);
    expect(await atLatest(page)).toBe(true);
    await probe(page, `[data-row-id="worked-t7-user"] button.cv-worked`);
    const opened = await clickAndWatch(page);
    expect(await page.locator("[data-probe]").getAttribute("aria-expanded")).toBe("true");
    expect(opened.moved).toBeLessThanOrEqual(1);
    expect(await page.locator('[data-row-id="t7-run"]').count()).toBe(1);
    await page.close();
  });

  test("mid-transcript, Worked for opens and closes with its line on its pixel", async () => {
    const page = await open("no-preference");
    await show(page, done);
    await settle(page);
    // Up the transcript, with turn 3's line about a third of the way down the view.
    await page.evaluate(() => {
      const scroller = document.querySelector<HTMLElement>(".acpmux-scroll")!;
      for (let step = 0; step < 40 && !document.querySelector('[data-row-id="worked-t3-user"]'); step += 1) {
        scroller.scrollTop = Math.max(0, scroller.scrollTop - scroller.clientHeight / 2);
        scroller.dispatchEvent(new Event("scroll"));
      }
    });
    await settle(page);
    await page.evaluate(() => {
      const scroller = document.querySelector<HTMLElement>(".acpmux-scroll")!;
      const line = document.querySelector<HTMLElement>('[data-row-id="worked-t3-user"] button.cv-worked')!;
      scroller.scrollTop += line.getBoundingClientRect().top - scroller.getBoundingClientRect().top - 200;
    });
    await settle(page);
    expect(await atLatest(page)).toBe(false);
    await probe(page, `[data-row-id="worked-t3-user"] button.cv-worked`);
    const worked = await clickAndWatch(page);
    expect(await page.locator("[data-probe]").getAttribute("aria-expanded")).toBe("true");
    expect(worked.moved).toBeLessThanOrEqual(1);
    await settle(page);
    await page.evaluate(() => document.querySelector("[data-probe]")?.removeAttribute("data-probe"));

    await probe(page, `[data-row-id="worked-t3-user"] button.cv-worked`);
    const workedClosed = await clickAndWatch(page);
    expect(await page.locator("[data-probe]").getAttribute("aria-expanded")).toBe("false");
    expect(workedClosed.moved).toBeLessThanOrEqual(1);
    await settle(page);
    // No copy of a hidden row is left behind, and the closed turn is one line again.
    expect(await page.locator(".acpmux-row--fold-ghost").count()).toBe(0);
    expect(await page.locator('[data-row-id="t3-run"]').count()).toBe(0);
    await page.close();
  });

  // Every kind of collapsible, opened and closed mid-transcript: the line the reader clicked stays on
  // its pixel (Show more holds the bubble's top: the text grows below it), and no element ever runs
  // two animations at once (Leo 2026-10-22: "a few animations that didnt quite work for collapsing
  // and expanding wrt tool calls and stufff").
  const longPrompt = Array.from({ length: 24 }, (_, line) => `${line + 1}. The uploader retries on a 5xx.`).join("\n");
  const execute = (id: string, command: string) => ({
    kind: "tool",
    text: "",
    tool: { id, title: command, kind: "execute", status: "completed", command, output: "3 pass\n0 fail", exitCode: 0 },
  });
  const kinds: Row[] = [
    row("k-user", "user", longPrompt),
    row("k-run", "activity", undefined, {
      items: [
        {
          kind: "thought",
          text: "Check the retry wrapper first.\n\nIt swallows the status.",
          startedAt: 0,
          endedAt: 9_000,
        },
        read("k-read"),
        execute("k-cmd-a", "bun test src/net"),
        execute("k-cmd-b", "bun test src/net --watch"),
      ],
    }),
    // Enough below the prompt that Show less, held at its button, never meets the end of the transcript.
    row("k-answer", "assistant", paragraphs(12)),
  ];
  /// Each kind: its toggle (by structure, not by label: the harness page loads no string table, so labels
  /// are keys), and for Show more what holds still while it opens.
  const run = '[data-row-id="k-run"] button.cv-tool.is-toggle';
  const cases: { name: string; toggle: string; text?: string; not?: string; held?: string }[] = [
    { name: "a thought", toggle: `${run}.cv-thought` },
    { name: "a tool call", toggle: `${run}:not(.cv-thought):not(.cv-command)`, text: "k-read" },
    { name: "a command group", toggle: `${run}:not(.cv-thought):not(.cv-command)`, not: "k-read" },
    {
      name: "Show more",
      toggle: '[data-row-id="k-user"] .cv-user__more',
      held: `[data-row-id="k-user"] .cv-user__bubble`,
    },
  ];
  for (const one of cases)
    test(`${one.name} opens and closes with its line on its pixel and one animation per element`, async () => {
      const page = await open("no-preference");
      await show(page, [...done, ...kinds]);
      await settle(page);
      // Marks the toggle (`data-toggle`) and puts it 200 px down the view, away from either end.
      const mark = () =>
        page.evaluate(({ toggle, text, not }) => {
          for (const node of document.querySelectorAll("[data-toggle]")) node.removeAttribute("data-toggle");
          const found = [...document.querySelectorAll<HTMLElement>(toggle)].find(
            (node) =>
              node.hasAttribute("aria-expanded") &&
              (!text || node.textContent?.includes(text)) &&
              !(not && node.textContent?.includes(not)),
          )!;
          found.dataset.toggle = "true";
          return found.getAttribute("aria-expanded") === "true";
        }, one);
      // A kind can start open (the latest command group does), so the first click closes it.
      const startsOpen = await mark();
      for (const opening of [!startsOpen, startsOpen]) {
        await mark();
        await page.evaluate(() => {
          const scroller = document.querySelector<HTMLElement>(".acpmux-scroll")!;
          const toggle = document.querySelector<HTMLElement>("[data-toggle]")!;
          scroller.scrollTop += toggle.getBoundingClientRect().top - scroller.getBoundingClientRect().top - 200;
        });
        await settle(page);
        const at = await page.evaluate(() => {
          const box = document.querySelector<HTMLElement>("[data-toggle]")!.getBoundingClientRect();
          return { x: box.left + Math.min(24, box.width / 2), y: box.top + box.height / 2 };
        });
        await page.evaluate(() => document.querySelector("[data-probe]")?.removeAttribute("data-probe"));
        // Show more holds the bubble's top while the text grows below it; Show less holds the button.
        await probe(page, opening && one.held ? one.held : "[data-toggle]");
        const watched = await clickAndWatch(page, 450, at);
        expect({ opening, held: watched.moved <= 1 }).toEqual({ opening, held: true });
        expect({ opening, stacked: Math.min(watched.stacked, 2) }).toEqual({ opening, stacked: 1 });
        await settle(page);
        await mark();
        expect(await page.locator("[data-toggle]").getAttribute("aria-expanded")).toBe(String(opening));
      }
      await page.close();
    });

  test("Show less on a prompt several screens tall, with motion off, keeps its button on its pixel", async () => {
    const page = await open("reduce");
    const tall = Array.from({ length: 400 }, (_, line) => `${line + 1}. The uploader retries on a 5xx.`).join("\n");
    await show(page, [
      ...done,
      row("tall-user", "user", tall),
      ...done.map((one) => ({ ...one, id: `after-${one.id}` })),
    ]);
    await settle(page);
    const button = '[data-row-id="tall-user"] .cv-user__more';
    // The prompt sits mid-transcript, so the view first walks up until its row is mounted, then puts
    // the button 200 px down. Rows that mount on the way are measured and shift it, so it tries again
    // until the button rests there.
    const place = async () => {
      for (let attempt = 0; attempt < 6; attempt += 1) {
        await page.evaluate(async (query) => {
          const scroller = document.querySelector<HTMLElement>(".acpmux-scroll")!;
          for (let step = 0; step < 40 && !document.querySelector(query); step += 1) {
            scroller.scrollTop -= scroller.clientHeight / 2;
            await window.cmuxPaintFrame();
          }
          const more = document.querySelector<HTMLElement>(query)!;
          scroller.scrollTop += more.getBoundingClientRect().top - scroller.getBoundingClientRect().top - 200;
        }, button);
        await settle(page);
        const off = await page.evaluate((query) => {
          const scroller = document.querySelector<HTMLElement>(".acpmux-scroll")!;
          const top = document.querySelector<HTMLElement>(query)?.getBoundingClientRect().top;
          return top === undefined ? Infinity : Math.abs(top - scroller.getBoundingClientRect().top - 200);
        }, button);
        if (off <= 1) return;
      }
    };
    await place();
    await page.locator(button).click();
    await settle(page);
    expect(await page.locator(button).getAttribute("aria-expanded")).toBe("true");
    await place();
    await page.evaluate(() => document.querySelector("[data-probe]")?.removeAttribute("data-probe"));
    await probe(page, button);
    const closed = await clickAndWatch(page, 250);
    expect(closed.moved).toBeLessThanOrEqual(1);
    expect(await page.locator(button).getAttribute("aria-expanded")).toBe("false");
    expect(Math.abs((await probedTop(page)) - closed.top)).toBeLessThanOrEqual(1);
    await page.close();
  });

  test("under Reduce Motion a tool call opens at once, and still stays on its pixel", async () => {
    const page = await open("reduce");
    await show(page, [...done, ...live(1)]);
    await settle(page);
    await probe(page, `[data-row-id="live-run"] button.cv-tool.is-toggle[aria-expanded="false"]`);
    const opened = await clickAndWatch(page, 250);
    expect(await page.locator("[data-probe]").getAttribute("aria-expanded")).toBe("true");
    expect(opened.folded).toBe(false);
    expect(opened.moved).toBeLessThanOrEqual(1);
    await page.close();
  });
});
