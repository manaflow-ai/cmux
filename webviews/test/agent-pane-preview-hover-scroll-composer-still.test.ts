// cmux-web-test-timeout: 400
// l10n-allow-file: test fixture prompts, not shipped UI.
// Scrolling the transcript with the pointer resting on a sent screenshot leaves the composer still: no
// React render of it, no element in it restyled, no paint of it, and its focus as it was (Leo,
// 2026-11-08: "when I was hovering over a preview of a screenshot or whatever and then scrolling, I was
// getting these rapid flickers, re-renders of the composer area. In fact, this composer area right
// now, as I'm dictating, I guess, like there was like a partial focus or something of the sort").
//
// A still pointer over a moving transcript changes what is under it on every scroll frame: thumbnails,
// prompt rows and replies slide in and out under it, each a hover change. The rule
// (chat-instant-under-load): a frame costs the rows on screen and what changed, so a hover change
// re-renders, restyles and repaints nothing outside the row under the pointer.
//
// The page is the pane's dev entry with the in-page mock daemon, a chat whose every prompt carries a
// screenshot (`seedRows(count, "images")`, imagesFixture.ts). The composer holds a draft and the
// keyboard; the pointer rests on a thumbnail; real wheel steps scroll the transcript up under it, one
// per frame. Then the same with words arriving in the composer between the steps, as dictation puts
// them in (no key event; `insertText`). Counted over the steps: the composer's renders (acpmuxPerf),
// its elements marked for a style recalc and its paints (Chromium's trace, by DOM node), what was
// under the pointer, and on every frame whether the prompt has the focus, the box matches
// `:focus-within`, and the page counts as key (`:root[data-page-inactive]`, pageKey.ts).
//
// Real Chromium and WebKit (WebKit draws the pane in cmux NEXT); the trace counts are Chromium's.
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, webkit, type Browser, type BrowserType, type CDPSession, type Page } from "playwright";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { warmViteServer } from "./support/warmDevServer";
import { COMPOSER_EDITOR } from "../src/agent-session/acpmux/composerSelectors";

const COMPOSER = "form.acpmux-composer";
const THUMBNAIL = ".cv-user__images button";
const STEPS = 30;
const STEP_PX = 90;

type Probe = {
  frames: number;
  focusLost: number;
  focusWithinFlips: number;
  inactiveFlips: number;
  composerMutations: number;
  under: string[];
  intervals: number[];
};
type Ev = { name: string; ph: string; ts: number; dur?: number; tid: number; pid: number; args?: any };

await requireBrowserLane("agent-pane-preview-hover-scroll-composer-still.test.ts", async () => {
  setDefaultTimeout(380_000);
  const { createServer } = await import("vite");
  const webviews = path.resolve(import.meta.dir, "..");
  let vite: Awaited<ReturnType<typeof createServer>> | undefined;
  let base = "";
  beforeAll(async () => {
    vite = await createServer({
      configFile: path.join(webviews, "vite.config.acpmux-pane.mjs"),
      server: { port: 0, host: "127.0.0.1", strictPort: false, watch: { ignored: () => true } },
      logLevel: "error",
    });
    await vite.listen();
    await warmViteServer(vite, "/?mock");
    const { port } = vite.httpServer!.address() as { port: number };
    base = `http://127.0.0.1:${port}`;
  });
  afterAll(async () => {
    await vite?.close();
  });

  const twoFrames = () =>
    new Promise<void>((resolve) => requestAnimationFrame(() => requestAnimationFrame(() => resolve())));

  /// The pane with the screenshot chat, a draft in the focused composer and the pointer resting on a
  /// thumbnail in the middle of the view.
  async function openPane(browser: Browser): Promise<Page> {
    const page = await browser.newPage({ viewport: { width: 900, height: 760 } });
    await page.goto(`${base}/?mock`);
    await page.waitForFunction(() => "cmuxAcpmuxDebug" in window, null, { timeout: 60_000 });
    const seeded = (await page.evaluate(() => (window as any).cmuxAcpmuxDebug.seedRows(240, "images"))) as Record<
      string,
      unknown
    >;
    expect(seeded.error).toBeUndefined();
    await page.locator(THUMBNAIL).first().waitFor({ timeout: 30_000 });
    await page.locator(COMPOSER_EDITOR).click();
    await page.keyboard.type("look at the screenshot");
    // Up a few screens, so the wheel has room above and below.
    await page.mouse.move(450, 300);
    for (let i = 0; i < 8; i += 1) await page.mouse.wheel(0, -400);
    await page.evaluate(twoFrames);
    const box = await page.evaluate((selector) => {
      const view = document.querySelector(".acpmux-scroll")!.getBoundingClientRect();
      const middle = view.top + view.height / 2;
      const shots = [...document.querySelectorAll<HTMLElement>(selector)].map((node) => node.getBoundingClientRect());
      const shot = shots
        .filter((rect) => rect.height > 0 && rect.top > view.top + 40 && rect.bottom < view.bottom - 200)
        .sort((a, b) => Math.abs(a.top - middle) - Math.abs(b.top - middle))[0];
      return shot && { x: shot.left + shot.width / 2, y: shot.top + shot.height / 2 };
    }, THUMBNAIL);
    expect(box, "a thumbnail in view").toBeTruthy();
    await page.mouse.move(box!.x, box!.y);
    // The hover's dwell (hover cards, the title tooltip) has passed: the pointer rests.
    await page.waitForTimeout(800);
    await page.evaluate(twoFrames);
    expect(
      await page.evaluate(({ x, y, selector }) => Boolean(document.elementFromPoint(x, y)?.closest(selector)), {
        ...box!,
        selector: THUMBNAIL,
      }),
      "the pointer rests on a thumbnail",
    ).toBe(true);
    return page;
  }

  /// Watches the composer on every frame until `stop`: its focus, `:focus-within`, the page's key
  /// mark, its DOM, and what is under the pointer.
  async function startProbe(page: Page) {
    await page.evaluate(
      ({ composer, editor }) => {
        const form = document.querySelector<HTMLElement>(composer)!;
        const box = form.querySelector<HTMLElement>(".acpmux-composer-box") ?? form;
        const prompt = form.querySelector<HTMLElement>(editor)!;
        const probe: Probe = {
          frames: 0,
          focusLost: 0,
          focusWithinFlips: 0,
          inactiveFlips: 0,
          composerMutations: 0,
          under: [],
          intervals: [],
        };
        const mutations = new MutationObserver((records) => {
          // Words the test puts in the prompt are its own change, not the composer's churn.
          probe.composerMutations += records.filter((record) => !prompt.contains(record.target)).length;
        });
        mutations.observe(form, { subtree: true, childList: true, attributes: true });
        let within = box.matches(":focus-within");
        let inactive = document.documentElement.hasAttribute("data-page-inactive");
        let last = performance.now();
        let running = true;
        const tick = (now: number) => {
          if (!running) return;
          probe.frames += 1;
          probe.intervals.push(now - last);
          last = now;
          if (document.activeElement !== prompt && !prompt.contains(document.activeElement)) probe.focusLost += 1;
          const nextWithin = box.matches(":focus-within");
          if (nextWithin !== within) probe.focusWithinFlips += 1;
          within = nextWithin;
          const nextInactive = document.documentElement.hasAttribute("data-page-inactive");
          if (nextInactive !== inactive) probe.inactiveFlips += 1;
          inactive = nextInactive;
          requestAnimationFrame(tick);
        };
        requestAnimationFrame(tick);
        const over = (event: PointerEvent | MouseEvent) => {
          const target = event.target as Element | null;
          const row = target?.closest?.(".acpmux-row");
          probe.under.push(`${row?.getAttribute("data-row-id") ?? "-"} ${target?.tagName ?? "-"}`);
        };
        document.addEventListener("mouseover", over, true);
        (window as any).__probeStop = () => {
          running = false;
          mutations.disconnect();
          document.removeEventListener("mouseover", over, true);
          return probe;
        };
      },
      { composer: COMPOSER, editor: COMPOSER_EDITOR },
    );
  }

  /// Wheel steps under the still pointer, one per frame; with `dictate`, a word arrives in the prompt
  /// between steps as dictation puts it in.
  async function scroll(page: Page, dictate: boolean) {
    for (let step = 0; step < STEPS; step += 1) {
      await page.mouse.wheel(0, step < STEPS / 2 ? -STEP_PX : STEP_PX);
      if (dictate)
        await page.evaluate(
          ([editor, word]) => {
            const field = document.querySelector<HTMLElement>(editor)!;
            if (document.activeElement !== field) return;
            document.execCommand("insertText", false, ` ${word}`);
          },
          [COMPOSER_EDITOR, `word${step}`] as const,
        );
      await page.evaluate(twoFrames);
    }
    // The hover update after the last scroll comes after a short timer in Chromium.
    await page.waitForTimeout(200);
    await page.evaluate(twoFrames);
  }

  /// The composer's DOM nodes by the backend id a trace names them with.
  async function composerNodes(cdp: CDPSession): Promise<Set<number>> {
    const { root } = (await cdp.send("DOM.getDocument", { depth: -1 })) as { root: any };
    const ids = new Set<number>();
    const walk = (node: any, inside: boolean) => {
      const classes = String(
        (node.attributes as string[] | undefined)?.find((_, i, all) => all[i - 1] === "class") ?? "",
      );
      const here = inside || (node.localName === "form" && classes.split(/\s+/).includes("acpmux-composer"));
      if (here && node.nodeType === 1) ids.add(node.backendNodeId);
      for (const child of node.children ?? []) walk(child, here);
      for (const child of node.shadowRoots ?? []) walk(child, here);
    };
    walk(root, false);
    return ids;
  }

  function composerTraceCounts(events: Ev[], nodes: Set<number>) {
    const restyled = new Set<number>();
    let marks = 0;
    let paints = 0;
    for (const event of events) {
      const data = event.args?.data ?? {};
      if (event.name === "StyleRecalcInvalidationTracking" || event.name === "StyleInvalidatorInvalidationTracking") {
        if (nodes.has(Number(data.nodeId))) {
          marks += 1;
          restyled.add(Number(data.nodeId));
        }
      } else if (event.name === "Paint" && nodes.has(Number(data.nodeId))) paints += 1;
    }
    return { composer_restyled: restyled.size, composer_restyle_marks: marks, composer_paints: paints };
  }

  const engines: [string, BrowserType][] = [
    ["chromium", chromium],
    ["webkit", webkit],
  ];
  for (const [name, engine] of engines)
    describe(name, () => {
      let browser: Browser | undefined;
      beforeAll(async () => {
        browser = await engine.launch({ headless: true });
      });
      afterAll(async () => {
        await browser?.close();
      });

      for (const dictate of [false, true])
        test(`scrolling under a pointer resting on a screenshot${dictate ? " while dictation types" : ""} leaves the composer still`, async () => {
          const page = await openPane(browser!);
          const cdp = name === "chromium" ? await page.context().newCDPSession(page) : undefined;
          const nodes = cdp ? await composerNodes(cdp) : new Set<number>();
          await page.evaluate(() => (window as any).cmuxAcpmuxDebug.renders());
          await startProbe(page);
          let events: Ev[] = [];
          if (cdp) {
            await browser!.startTracing(page, {
              categories: [
                "devtools.timeline",
                "disabled-by-default-devtools.timeline",
                "disabled-by-default-devtools.timeline.invalidationTracking",
              ],
            });
            await scroll(page, dictate);
            events = (JSON.parse((await browser!.stopTracing()).toString()) as { traceEvents: Ev[] }).traceEvents;
          } else await scroll(page, dictate);
          const probe = (await page.evaluate(() => (window as any).__probeStop())) as Probe;
          const renders = (await page.evaluate(() => (window as any).cmuxAcpmuxDebug.renders())) as Record<
            string,
            number
          >;
          await page.close();
          const composerRenders = Object.entries(renders)
            .filter(([part]) => part === "composer" || part.startsWith("composer:"))
            .reduce((sum, [, count]) => sum + count, 0);
          const sorted = [...probe.intervals].sort((a, b) => a - b);
          const report = {
            engine: name,
            dictate,
            steps: STEPS,
            frames: probe.frames,
            frame_p95_ms: Math.round((sorted[Math.floor(sorted.length * 0.95)] ?? 0) * 10) / 10,
            hover_changes: probe.under.length,
            hover_rows: new Set(probe.under.map((under) => under.split(" ")[0])).size,
            composer_renders: composerRenders,
            renders,
            focus_lost_frames: probe.focusLost,
            focus_within_flips: probe.focusWithinFlips,
            page_inactive_flips: probe.inactiveFlips,
            composer_mutations: probe.composerMutations,
            ...(cdp ? composerTraceCounts(events, nodes) : {}),
            composer_nodes: nodes.size,
          };
          console.log(`PREVIEW-HOVER-SCROLL ${JSON.stringify(report)}`);
          // The scroll moved rows under the pointer: the case Leo saw.
          expect(report.hover_changes, "hover changes under the still pointer").toBeGreaterThan(2);
          expect(report.focus_lost_frames, "frames the prompt did not have the focus").toBe(0);
          expect(report.focus_within_flips, "the composer box's :focus-within toggled").toBe(0);
          expect(report.page_inactive_flips, "the page's key mark toggled").toBe(0);
          if (!dictate) {
            expect(report.composer_renders, "composer renders").toBe(0);
            expect(report.composer_mutations, "composer nodes added, removed or re-attributed").toBe(0);
          }
          if (cdp) {
            expect(nodes.size, "the composer's nodes were found").toBeGreaterThan(10);
            if (!dictate) {
              expect(report.composer_restyled, "composer elements restyled").toBe(0);
              expect(report.composer_paints, "composer paints").toBe(0);
            }
          }
        });
    });
});
