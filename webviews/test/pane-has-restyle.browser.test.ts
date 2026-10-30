// cmux-web-test-timeout: 600
// Style invalidation in the agent pane, measured in Chromium from its own trace (UpdateLayoutTree
// elementCount): how many elements one DOM insertion, one streamed reply delta, one rail wheel step
// and opening a composer menu restyle, on the normal chat flows page and the 3,000-turn page.
//
// PANE_HAS_ABLATION=1 also removes each `:has()` rule in turn and prints how much of an insertion's
// restyle it accounts for (the search that found the pane-wide `:has()` rules).
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser, type Page } from "playwright";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { warmViteServer } from "./support/warmDevServer";

type Styled = { recalcs: number; elements: number[]; ms: number[] };

// A measurement, not a gate: it runs only when asked (PANE_HAS_MEASURE=1), through cmux-ci.
const measuring = process.env.PANE_HAS_MEASURE === "1";
if (!measuring)
  describe.skip("pane :has restyle (PANE_HAS_MEASURE=1)", () => test("chromium", () => {}));
else
  await requireBrowserLane("pane-has-restyle.browser.test.ts", async () => {
    setDefaultTimeout(300_000);
    try {
      await (await chromium.launch({ headless: true })).close();
    } catch {
      console.warn("pane-has-restyle: skipping (run `bunx playwright install chromium`)");
      describe.skip("pane :has restyle", () => test("chromium", () => {}));
      return;
    }
    const { createServer } = await import("vite");
    const webviews = path.resolve(import.meta.dir, "..");
    let vite: Awaited<ReturnType<typeof createServer>> | undefined;
    let browser: Browser | undefined;
    let base = "";

    beforeAll(async () => {
      vite = await createServer({
        root: webviews,
        configFile: path.join(webviews, "vite.config.ts"),
        server: { port: 0, host: "127.0.0.1", strictPort: false },
        logLevel: "error",
      });
      await vite.listen();
      await warmViteServer(vite, "/test/latency/flows.html");
      const { port } = vite.httpServer!.address() as { port: number };
      base = `http://127.0.0.1:${port}`;
      browser = await chromium.launch({ headless: true });
    }, 280_000);
    afterAll(async () => {
      await browser?.close();
      await vite?.close();
    });

    const twoFrames = `new Promise((resolve) => requestAnimationFrame(() => requestAnimationFrame(resolve)))`;

    /** Every style recalc Chromium traced while `run` ran: its element count and its duration. */
    async function traced(page: Page, run: () => Promise<unknown>): Promise<Styled> {
      await page.evaluate(twoFrames);
      await browser!.startTracing(page, {
        categories: ["devtools.timeline", "disabled-by-default-devtools.timeline"],
      });
      await run();
      const raw = JSON.parse((await browser!.stopTracing()).toString()) as {
        traceEvents: {
          name: string;
          ph: string;
          ts: number;
          dur?: number;
          tid: number;
          args?: any;
        }[];
      };
      const out: Styled = { recalcs: 0, elements: [], ms: [] };
      const open = new Map<number, number>();
      for (const event of raw.traceEvents.filter((e) => e.name === "UpdateLayoutTree")) {
        const count = event.args?.elementCount ?? event.args?.data?.elementCount;
        if (event.ph === "X") {
          out.recalcs += 1;
          out.elements.push(Number(count ?? 0));
          out.ms.push((event.dur ?? 0) / 1000);
        } else if (event.ph === "B") open.set(event.tid, event.ts);
        else if (event.ph === "E") {
          const began = open.get(event.tid);
          open.delete(event.tid);
          out.recalcs += 1;
          out.elements.push(Number(count ?? 0));
          out.ms.push(began === undefined ? 0 : (event.ts - began) / 1000);
        }
      }
      return out;
    }

    const sum = (values: number[]) => values.reduce((a, b) => a + b, 0);
    const quantile = (values: number[], q: number) => {
      if (!values.length) return 0;
      const sorted = [...values].sort((a, b) => a - b);
      return sorted[Math.min(sorted.length - 1, Math.floor(q * sorted.length))]!;
    };
    const round = (value: number) => Math.round(value * 100) / 100;
    const report = (page: string, scenario: string, values: Record<string, unknown>) =>
      console.log(`PANE-HAS ${JSON.stringify({ page, scenario, ...values })}`);

    async function openFlows(query: string): Promise<Page> {
      const page = await browser!.newPage({ viewport: { width: 1100, height: 800 } });
      page.on("pageerror", (error) =>
        console.warn(`pane-has-restyle page error: ${error.message}`),
      );
      await page.goto(`${base}/test/latency/flows.html?${query}`);
      await page.waitForFunction(
        () => document.documentElement.dataset.latencyFlowsReady === "true",
        undefined,
        {
          timeout: 200_000,
        },
      );
      await page.evaluate(() => {
        const scroll = document.querySelector<HTMLElement>(".acpmux-scroll")!;
        scroll.scrollTop = scroll.scrollHeight;
      });
      await page.evaluate(twoFrames);
      return page;
    }

    /** One element inserted into the last transcript row (as a streamed Markdown block adds one). */
    async function insertOnce(page: Page, tag: string): Promise<Styled> {
      const styled = await traced(page, () =>
        page.evaluate(
          async ({ tag, frames }) => {
            const rows = document.querySelectorAll(".acpmux-scroll .acpmux-row");
            const row = rows[rows.length - 1]!;
            const host = row.querySelector(".cv-md") ?? row;
            const node = document.createElement(tag);
            if (node instanceof HTMLButtonElement) node.type = "button";
            node.textContent = "probe";
            node.setAttribute("data-has-probe", "");
            host.append(node);
            await new Function(`return ${frames}`)();
          },
          { tag, frames: twoFrames },
        ),
      );
      await page.evaluate(() =>
        document.querySelectorAll("[data-has-probe]").forEach((node) => node.remove()),
      );
      await page.evaluate(twoFrames);
      return styled;
    }

    async function insertion(page: Page, tag: string, runs = 5) {
      const elements: number[] = [];
      const ms: number[] = [];
      for (let run = 0; run < runs; run += 1) {
        const styled = await insertOnce(page, tag);
        elements.push(sum(styled.elements));
        ms.push(sum(styled.ms));
      }
      return { elements: quantile(elements, 0.5), ms: round(quantile(ms, 0.5)) };
    }

    /** A streamed reply from the mock daemon: deltas every 16 ms for 2 s, as a busy agent's arrive. */
    async function stream(page: Page) {
      let frames: number[] = [];
      let deltas = 0;
      const styled = await traced(page, async () => {
        const result = (await page.evaluate(async () => {
          const { MockAcpmuxSocket } = await import("/src/agent-session/acpmux/mock.ts" as string);
          const sessionId = (window as any).__latencyFlows.sessionId as string;
          const stamps: number[] = [];
          let done = false;
          const tick = (now: number) => {
            stamps.push(now);
            if (!done) requestAnimationFrame(tick);
          };
          requestAnimationFrame(tick);
          const streamed = await MockAcpmuxSocket.live.streamLoadTurn(sessionId, {
            seconds: 2,
            chunkChars: 12,
            chunkMs: 16,
            toolEvery: 0,
          });
          done = true;
          return { stamps, deltas: streamed.deltas };
        })) as { stamps: number[]; deltas: number };
        frames = result.stamps.slice(1).map((stamp, index) => stamp - result.stamps[index]!);
        deltas = result.deltas;
      });
      await page.evaluate(twoFrames);
      return {
        deltas,
        recalcs: styled.recalcs,
        elementsPerRecalcP50: quantile(styled.elements, 0.5),
        elementsPerRecalcP95: quantile(styled.elements, 0.95),
        elementsPerDelta: Math.round(sum(styled.elements) / Math.max(1, deltas)),
        styleMsPerDelta: round(sum(styled.ms) / Math.max(1, deltas)),
        styleMsTotal: round(sum(styled.ms)),
        frameP95: round(quantile(frames, 0.95)),
      };
    }

    /** Ten wheel steps over the session rail's list, one per frame pair. */
    async function railWheel(page: Page) {
      const list = page.locator(".acpmux-minimap__list");
      if (!(await list.count())) return null;
      const box = await list.boundingBox();
      if (!box) return null;
      await page.mouse.move(box.x + box.width / 2, box.y + box.height / 2);
      await page.evaluate(twoFrames);
      const steps: Styled[] = [];
      for (let step = 0; step < 10; step += 1) {
        steps.push(
          await traced(page, async () => {
            await page.mouse.wheel(0, step < 5 ? -120 : 120);
            await page.evaluate(twoFrames);
          }),
        );
      }
      await page.mouse.move(1, 1);
      return {
        elementsPerStepP50: quantile(
          steps.map((s) => sum(s.elements)),
          0.5,
        ),
        styleMsPerStepP50: round(
          quantile(
            steps.map((s) => sum(s.ms)),
            0.5,
          ),
        ),
        styleMsPerStepP95: round(
          quantile(
            steps.map((s) => sum(s.ms)),
            0.95,
          ),
        ),
      };
    }

    /** The composer's slash menu opening (the field menu over the prompt). */
    async function slashMenu(page: Page) {
      const editor = ".acpmux-composer [contenteditable='true']";
      const runs: Styled[] = [];
      for (let run = 0; run < 3; run += 1) {
        await page.focus(editor);
        runs.push(
          await traced(page, async () => {
            await page.keyboard.type("/");
            await page
              .waitForSelector(".acpmux-slash-menu", { timeout: 10_000 })
              .catch(() => undefined);
            await page.evaluate(twoFrames);
          }),
        );
        await page.keyboard.press("Escape");
        await page.keyboard.press("Backspace");
        await page.evaluate(twoFrames);
      }
      return {
        elementsP50: quantile(
          runs.map((s) => sum(s.elements)),
          0.5,
        ),
        styleMsP50: round(
          quantile(
            runs.map((s) => sum(s.ms)),
            0.5,
          ),
        ),
      };
    }

    /** Each `:has()` style rule in the page's sheets, with where it sits so it can be put back. */
    const listHasRules = () => {
      const found: { selector: string; sheet: string }[] = [];
      const walk = (rules: CSSRuleList, sheet: string) => {
        for (const rule of Array.from(rules)) {
          if (rule instanceof CSSStyleRule && rule.selectorText.includes(":has(")) {
            found.push({ selector: rule.selectorText, sheet });
          }
          if ("cssRules" in rule && (rule as CSSGroupingRule).cssRules)
            walk((rule as CSSGroupingRule).cssRules, sheet);
        }
      };
      for (const sheet of Array.from(document.styleSheets)) {
        try {
          const owner = sheet.ownerNode as HTMLElement | null;
          walk(sheet.cssRules, owner?.getAttribute("data-vite-dev-id") ?? sheet.href ?? "inline");
        } catch {
          // A cross-origin sheet has no readable rules.
        }
      }
      return found;
    };

    /** Disables (or restores) the n-th `:has()` rule, or every one when n is -1. */
    const toggleHasRule = ({ n, off }: { n: number; off: boolean }) => {
      const w = window as any;
      w.__hasStash ??= new Map<
        number,
        { parent: CSSStyleSheet | CSSGroupingRule; index: number; text: string }
      >();
      const stash = w.__hasStash as Map<number, { parent: any; index: number; text: string }>;
      if (!off) {
        for (const [key, entry] of [...stash.entries()].sort((a, b) => b[0] - a[0])) {
          if (n !== -1 && key !== n) continue;
          entry.parent.insertRule(entry.text, entry.index);
          stash.delete(key);
        }
        return;
      }
      let seen = 0;
      const hits: { parent: any; index: number; key: number; text: string }[] = [];
      const walk = (parent: any) => {
        const rules = Array.from(parent.cssRules as CSSRuleList);
        rules.forEach((rule, index) => {
          if (rule instanceof CSSStyleRule && rule.selectorText.includes(":has(")) {
            const key = seen++;
            if (n === -1 || key === n) hits.push({ parent, index, key, text: rule.cssText });
          }
          if ("cssRules" in rule && (rule as CSSGroupingRule).cssRules) walk(rule);
        });
      };
      for (const sheet of Array.from(document.styleSheets)) {
        try {
          walk(sheet);
        } catch {
          // unreadable
        }
      }
      for (const hit of hits.sort((a, b) => b.index - a.index)) {
        hit.parent.deleteRule(hit.index);
        stash.set(hit.key, { parent: hit.parent, index: hit.index, text: hit.text });
      }
    };

    for (const [name, query] of [
      ["flows", "mock&recents=demo"],
      ["3000", "mock&turns=3000&resident"],
    ] as const) {
      test(`${name}: restyle per insertion, streamed delta, rail wheel step and menu open`, async () => {
        const page = await openFlows(query);
        try {
          for (const tag of ["div", "p", "button"])
            report(name, `insert-${tag}`, await insertion(page, tag));
          report(name, "rail-wheel", { result: await railWheel(page) });
          report(name, "slash-menu", await slashMenu(page));
          report(name, "stream", await stream(page));

          if (process.env.PANE_HAS_ABLATION === "1") {
            const rules = (await page.evaluate(listHasRules)) as {
              selector: string;
              sheet: string;
            }[];
            const before = await insertion(page, "button", 3);
            await page.evaluate(toggleHasRule, { n: -1, off: true });
            const none = await insertion(page, "button", 3);
            await page.evaluate(toggleHasRule, { n: -1, off: false });
            report(name, "ablation-all", { rules: rules.length, before, none });
            for (let n = 0; n < rules.length; n += 1) {
              await page.evaluate(toggleHasRule, { n, off: true });
              const without = await insertion(page, "button", 3);
              await page.evaluate(toggleHasRule, { n, off: false });
              if (before.elements - without.elements > 50)
                report(name, "ablation-rule", {
                  n,
                  ...rules[n],
                  before: before.elements,
                  without: without.elements,
                });
            }
          }
          expect(true).toBe(true);
        } finally {
          await page.close();
        }
      });
    }
  });
