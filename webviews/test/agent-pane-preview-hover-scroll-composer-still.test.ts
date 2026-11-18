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
// its elements marked for a style recalc, the whole-subtree restyles of an element it is inside (a
// pane-level `:has()`), and its paints (Chromium's trace, by DOM node); what was under the pointer;
// and on every frame whether the prompt has the focus, the box matches `:focus-within`, and the page
// counts as key (`:root[data-page-inactive]`, pageKey.ts).
//
// It does not fail on the base it landed on: the flicker was repaired before it (#40035, #41583,
// #43348). Two mutations show what it catches: a `.acpmux-main:has(.acpmux-row:hover)` rule over the
// composer box (88 whole-subtree restyles over the composer) and a composer render per `pointerover`
// (189 composer renders).
//
// Real Chromium and WebKit (WebKit draws the pane in cmux NEXT); the trace counts are Chromium's.
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, webkit, type Browser, type BrowserType, type CDPSession, type Page } from "playwright";
import { probeEngineOrSkip, requireBrowserLane } from "./support/requireBrowserLane";
import { warmViteServer } from "./support/warmDevServer";
import { COMPOSER_EDITOR } from "../src/agent-session/acpmux/composerSelectors";

const COMPOSER = "form.acpmux-composer";
/// Where the pointer rests: a screenshot sent with a prompt (its title tooltip), or the small image of
/// a screenshot the agent took (its hover preview card, conversation/ToolVisualPreview.tsx).
const TARGETS = {
  sent: ".cv-user__images button",
  tool: ".cv-tool-visual",
} as const;
type Target = keyof typeof TARGETS;
const TOOL_CARD = ".cv-tool-visual-card";
const STEPS = 30;
const STEP_PX = 90;

type Probe = {
  frames: number;
  focusLost: number;
  focusWithinFlips: number;
  inactiveFlips: number;
  composerMutations: number;
  mutationKinds: Record<string, number>;
  cardMounts: number;
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
  async function openPane(browser: Browser, target: Target): Promise<Page> {
    const THUMBNAIL = TARGETS[target];
    const page = await browser.newPage({ viewport: { width: 900, height: 760 } });
    await page.goto(`${base}/?mock`);
    await page.waitForFunction(() => "cmuxAcpmuxDebug" in window, null, { timeout: 60_000 });
    const seeded = (await page.evaluate(() => (window as any).cmuxAcpmuxDebug.seedRows(240, "images"))) as Record<
      string,
      unknown
    >;
    expect(seeded.error).toBeUndefined();
    await page.locator(TARGETS.sent).first().waitFor({ timeout: 30_000 });
    await page.locator(COMPOSER_EDITOR).click();
    await page.keyboard.type("look at the screenshot");
    // Up a few screens, so the wheel has room above and below.
    await page.mouse.move(450, 300);
    for (let i = 0; i < 8; i += 1) await page.mouse.wheel(0, -400);
    // The wheel's scroll and the rows it mounts settle before the thumbnail is picked.
    await page.waitForTimeout(600);
    await page.evaluate(twoFrames);
    if (target === "tool") {
      // A finished turn folds its calls into "Worked for 1s": open the one nearest the middle, the
      // screenshot's small image shows at its call's edge.
      const opened = await page.evaluate(() => {
        const view = document.querySelector(".acpmux-scroll")!.getBoundingClientRect();
        const middle = view.top + view.height / 2;
        const fold = [...document.querySelectorAll<HTMLElement>(".cv-worked.is-toggle[aria-expanded='false']")]
          .filter((node) => {
            const rect = node.getBoundingClientRect();
            return rect.height > 0 && rect.top > view.top && rect.bottom < view.bottom - 200;
          })
          .sort(
            (a, b) =>
              Math.abs(a.getBoundingClientRect().top - middle) - Math.abs(b.getBoundingClientRect().top - middle),
          )[0];
        fold?.click();
        return Boolean(fold);
      });
      expect(opened, "a folded turn in view").toBe(true);
      await page.locator(THUMBNAIL).first().waitFor({ timeout: 10_000 });
      await page.waitForTimeout(600);
      await page.evaluate(twoFrames);
      // The click on the fold took the keyboard: give it back to the prompt, caret at the end.
      await page.locator(COMPOSER_EDITOR).focus();
    }
    const box = await page.evaluate((selector) => {
      const view = document.querySelector(".acpmux-scroll")!.getBoundingClientRect();
      const middle = view.top + view.height / 2;
      const shots = [...document.querySelectorAll<HTMLElement>(selector)].map((node) => node.getBoundingClientRect());
      const shot = shots
        .filter((rect) => rect.height > 0 && rect.top > view.top + 40 && rect.bottom < view.bottom - 160)
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
    if (target === "tool") await page.locator(TOOL_CARD).waitFor({ timeout: 5_000 });
    return page;
  }

  /// Watches the composer on every frame until `stop`: its focus, `:focus-within`, the page's key
  /// mark, its DOM, and what is under the pointer.
  async function startProbe(page: Page) {
    await page.evaluate(
      ({ composer, editor, card }) => {
        const form = document.querySelector<HTMLElement>(composer)!;
        const box = form.querySelector<HTMLElement>(".acpmux-composer-box") ?? form;
        const prompt = form.querySelector<HTMLElement>(editor)!;
        const probe: Probe = {
          frames: 0,
          focusLost: 0,
          focusWithinFlips: 0,
          inactiveFlips: 0,
          composerMutations: 0,
          mutationKinds: {},
          cardMounts: 0,
          under: [],
          intervals: [],
        };
        const mutations = new MutationObserver((records) => {
          // Words the test puts in the prompt are its own change, not the composer's churn.
          for (const record of records) {
            if (prompt.contains(record.target)) continue;
            probe.composerMutations += 1;
            const node = record.target as Element;
            const kind = `${record.type} ${node.nodeName?.toLowerCase()}.${String(node.className?.baseVal ?? node.className ?? "").split(" ")[0]} ${record.attributeName ?? ""}`;
            probe.mutationKinds[kind] = (probe.mutationKinds[kind] ?? 0) + 1;
          }
        });
        mutations.observe(form, { subtree: true, childList: true, attributes: true });
        const cards = new MutationObserver((records) => {
          for (const record of records)
            for (const node of record.addedNodes)
              if (node instanceof Element && (node.matches(card) || node.querySelector(card))) probe.cardMounts += 1;
        });
        cards.observe(document.body, { childList: true, subtree: true });
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
          cards.disconnect();
          document.removeEventListener("mouseover", over, true);
          return probe;
        };
      },
      { composer: COMPOSER, editor: COMPOSER_EDITOR, card: TOOL_CARD },
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

  /// The composer's DOM nodes by the backend id a trace names them with, and its ancestors: a style
  /// invalidation on one of those that covers its whole subtree (a pane-level `:has()` rule) restyles
  /// the composer too, though the trace names none of its nodes.
  async function composerNodes(cdp: CDPSession): Promise<{ nodes: Set<number>; ancestors: Set<number> }> {
    const { root } = (await cdp.send("DOM.getDocument", { depth: -1 })) as { root: any };
    const nodes = new Set<number>();
    const ancestors = new Set<number>();
    const walk = (node: any, path: number[], inside: boolean) => {
      const classes = String(
        (node.attributes as string[] | undefined)?.find((_, i, all) => all[i - 1] === "class") ?? "",
      );
      const top = !inside && node.localName === "form" && classes.split(/\s+/).includes("acpmux-composer");
      if (top) for (const id of path) ancestors.add(id);
      const here = inside || top;
      if (here && node.nodeType === 1) nodes.add(node.backendNodeId);
      const next = [...path, node.backendNodeId];
      for (const child of node.children ?? []) walk(child, next, here);
      for (const child of node.shadowRoots ?? []) walk(child, next, here);
    };
    walk(root, [], false);
    return { nodes, ancestors };
  }

  function composerTraceCounts(events: Ev[], { nodes, ancestors }: { nodes: Set<number>; ancestors: Set<number> }) {
    const restyled = new Set<number>();
    let marks = 0;
    let paints = 0;
    let covering = 0;
    let recalcs = 0;
    let elements = 0;
    for (const event of events) {
      const data = event.args?.data ?? {};
      if (event.name === "UpdateLayoutTree" && event.ph !== "E") {
        recalcs += 1;
        elements += Number(event.args?.elementCount ?? data.elementCount ?? 0);
      }
      if (event.name === "StyleRecalcInvalidationTracking" || event.name === "StyleInvalidatorInvalidationTracking") {
        if (nodes.has(Number(data.nodeId))) {
          marks += 1;
          restyled.add(Number(data.nodeId));
        } else if (
          ancestors.has(Number(data.nodeId)) &&
          (data.subtree === true ||
            (data.invalidationList as { allDescendantsMightBeInvalid?: boolean }[] | undefined)?.some(
              (set) => set.allDescendantsMightBeInvalid,
            ))
        )
          covering += 1;
      } else if (event.name === "Paint" && nodes.has(Number(data.nodeId))) paints += 1;
    }
    return {
      composer_restyled: restyled.size,
      composer_restyle_marks: marks,
      // Whole-subtree restyles of an element the composer is inside.
      composer_covering_marks: covering,
      composer_paints: paints,
      // The whole page's style recalcs over the steps, for scale: the rows the scroll mounts restyle.
      page_recalcs: recalcs,
      page_restyled: elements,
    };
  }

  const engines: [string, BrowserType][] = [
    ["chromium", chromium],
    ["webkit", webkit],
  ];
  for (const [name, engine] of engines) {
    if (!(await probeEngineOrSkip(`agent-pane-preview-hover-scroll-composer-still (${name})`, name, engine))) continue;
    describe(name, () => {
      let browser: Browser | undefined;
      beforeAll(async () => {
        browser = await engine.launch({ headless: true });
      });
      afterAll(async () => {
        await browser?.close();
      });

      for (const target of Object.keys(TARGETS) as Target[])
        for (const dictate of [false, true])
          test(`scrolling under a pointer resting on a ${target === "sent" ? "sent screenshot" : "tool screenshot's preview"}${dictate ? " while dictation types" : ""} leaves the composer still`, async () => {
            const page = await openPane(browser!, target);
            const cdp = name === "chromium" ? await page.context().newCDPSession(page) : undefined;
            const composer = cdp
              ? await composerNodes(cdp)
              : { nodes: new Set<number>(), ancestors: new Set<number>() };
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
              target,
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
              mutation_kinds: probe.mutationKinds,
              card_mounts: probe.cardMounts,
              ...(cdp ? composerTraceCounts(events, composer) : {}),
              composer_nodes: composer.nodes.size,
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
              expect(composer.nodes.size, "the composer's nodes were found").toBeGreaterThan(10);
              if (!dictate) {
                expect(report.composer_restyled, "composer elements restyled").toBe(0);
                expect(report.composer_covering_marks, "whole-subtree restyles over the composer").toBe(0);
                expect(report.composer_paints, "composer paints").toBe(0);
              }
            }
          });
    });
  }
});
