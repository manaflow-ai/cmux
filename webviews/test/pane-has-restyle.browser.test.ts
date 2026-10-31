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

await requireBrowserLane("pane-has-restyle.browser.test.ts", async () => {
  // A measurement, not a gate: it runs only when asked (PANE_HAS_MEASURE=1), through cmux-ci.
  if (process.env.PANE_HAS_MEASURE !== "1") {
    describe.skip("pane :has restyle (PANE_HAS_MEASURE=1)", () => test("chromium", () => {}));
    return;
  }
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
    page.on("pageerror", (error) => console.warn(`pane-has-restyle page error: ${error.message}`));
    await page.goto(`${base}/test/latency/flows.html?${query}`);
    await page.waitForFunction(() => document.documentElement.dataset.latencyFlowsReady === "true", undefined, {
      timeout: 200_000,
    });
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
        async ({ tag }) => {
          const rows = document.querySelectorAll(".acpmux-scroll .acpmux-row");
          const row = rows[rows.length - 1]!;
          const host = row.querySelector(".cv-md") ?? row;
          const node = document.createElement(tag);
          if (node instanceof HTMLButtonElement) node.type = "button";
          node.textContent = "probe";
          node.setAttribute("data-has-probe", "");
          host.append(node);
          await new Promise((resolve) => requestAnimationFrame(() => requestAnimationFrame(resolve)));
        },
        { tag },
      ),
    );
    await page.evaluate(() => document.querySelectorAll("[data-has-probe]").forEach((node) => node.remove()));
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
          // raf-read: the frame intervals are the rAF timestamps themselves; nothing reads layout.
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
          await page.waitForSelector(".acpmux-slash-menu", { timeout: 10_000 }).catch(() => undefined);
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
        if ("cssRules" in rule && (rule as CSSGroupingRule).cssRules) walk((rule as CSSGroupingRule).cssRules, sheet);
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

  /** Disables (or restores) the n-th `:has()` rule (listHasRules' order), or every one when n is
   *  -1. Each rule keeps its slot, so a rule goes back where it was among the rules still there. */
  const toggleHasRule = ({ n, off }: { n: number; off: boolean }) => {
    type Slot = { parent: any; siblings: CSSRule[]; rule: CSSRule; text: string; present: boolean };
    const w = window as any;
    if (!w.__hasRules) {
      const slots: Slot[] = [];
      const walk = (parent: any) => {
        const siblings = Array.from(parent.cssRules as CSSRuleList);
        for (const rule of siblings) {
          if (rule instanceof CSSStyleRule && rule.selectorText.includes(":has("))
            slots.push({ parent, siblings, rule, text: rule.cssText, present: true });
          if ("cssRules" in rule && (rule as CSSGroupingRule).cssRules) walk(rule);
        }
      };
      for (const sheet of Array.from(document.styleSheets)) {
        try {
          walk(sheet);
        } catch {
          // A cross-origin sheet has no readable rules.
        }
      }
      w.__hasRules = slots;
    }
    const slots = w.__hasRules as Slot[];
    for (const slot of n === -1 ? slots : [slots[n]!]) {
      if (off && slot.present) {
        slot.parent.deleteRule(Array.from(slot.parent.cssRules as CSSRuleList).indexOf(slot.rule));
        slot.present = false;
      } else if (!off && !slot.present) {
        const live = new Set(Array.from(slot.parent.cssRules as CSSRuleList));
        const at = slot.siblings.indexOf(slot.rule);
        const index = slot.siblings.slice(0, at).filter((rule) => live.has(rule)).length;
        slot.parent.insertRule(slot.text, index);
        slot.rule = slot.parent.cssRules[index];
        slot.siblings[at] = slot.rule;
        slot.present = true;
      }
    }
  };

  /** Why one inserted button restyles what it does: Chromium's invalidation tracking, grouped. */
  async function why(page: Page) {
    await page.evaluate(twoFrames);
    await browser!.startTracing(page, {
      categories: ["devtools.timeline", "disabled-by-default-devtools.timeline.invalidationTracking"],
    });
    await page.evaluate(async () => {
      const rows = document.querySelectorAll(".acpmux-scroll .acpmux-row");
      const row = rows[rows.length - 1]!;
      const node = document.createElement("button");
      node.type = "button";
      node.textContent = "probe";
      node.setAttribute("data-has-probe", "");
      (row.querySelector(".cv-md") ?? row).append(node);
      await new Promise((resolve) => requestAnimationFrame(() => requestAnimationFrame(resolve)));
    });
    const raw = JSON.parse((await browser!.stopTracing()).toString()) as {
      traceEvents: { name: string; cat: string; args?: any }[];
    };
    await page.evaluate(() => document.querySelectorAll("[data-has-probe]").forEach((node) => node.remove()));
    const kinds = new Map<string, number>();
    const nodes = new Map<string, number>();
    for (const event of raw.traceEvents) {
      if (!event.cat.includes("invalidationTracking")) continue;
      const data = event.args?.data ?? {};
      const key = [
        event.name,
        data.reason,
        data.changedPseudo && `pseudo ${data.changedPseudo}`,
        data.changedAttribute && `attr ${data.changedAttribute}`,
        data.changedClass && `class ${data.changedClass}`,
        data.invalidationList && JSON.stringify(data.invalidationList).slice(0, 160),
      ]
        .filter(Boolean)
        .join(" | ");
      kinds.set(key, (kinds.get(key) ?? 0) + 1);
      if (event.name === "StyleRecalcInvalidationTracking") {
        const name = `${data.nodeName ?? "?"}`;
        nodes.set(name, (nodes.get(name) ?? 0) + 1);
      }
    }
    const top = (map: Map<string, number>) => [...map.entries()].sort((a, b) => b[1] - a[1]).slice(0, 12);
    return { kinds: top(kinds), nodes: top(nodes) };
  }

  for (const [name, query] of [
    ["flows", "mock&recents=demo"],
    ["3000", "mock&turns=3000&resident"],
  ] as const) {
    test(`${name}: restyle per insertion, streamed delta, rail wheel step and menu open`, async () => {
      const page = await openFlows(query);
      try {
        for (const tag of ["div", "p", "button"]) report(name, `insert-${tag}`, await insertion(page, tag));
        report(name, "rail-wheel", { result: await railWheel(page) });
        report(name, "slash-menu", await slashMenu(page));
        report(name, "stream", await stream(page));

        if (process.env.PANE_HAS_ABLATION === "1") {
          report(name, "why", await why(page));
          const rules = (await page.evaluate(listHasRules)) as { selector: string; sheet: string }[];
          const before = await insertion(page, "button", 3);
          await page.evaluate(toggleHasRule, { n: -1, off: true });
          const none = await insertion(page, "button", 3);
          report(name, "ablation-all", { rules: rules.length, before, none });
          // Every :has() rule off but one: what that rule alone costs an insertion.
          const costly: number[] = [];
          for (let n = 0; n < rules.length; n += 1) {
            await page.evaluate(toggleHasRule, { n, off: false });
            const alone = await insertion(page, "button", 3);
            await page.evaluate(toggleHasRule, { n, off: true });
            if (alone.elements - none.elements > 20) {
              costly.push(n);
              report(name, "alone-rule", { n, ...rules[n], none: none.elements, alone: alone.elements });
            }
          }
          for (const n of costly.slice(0, 3)) {
            await page.evaluate(toggleHasRule, { n, off: false });
            report(name, "why-alone", { n, ...(await why(page)) });
            await page.evaluate(toggleHasRule, { n, off: true });
          }
          // Every rule back but the costly ones: what is left.
          await page.evaluate(toggleHasRule, { n: -1, off: false });
          for (const n of costly) await page.evaluate(toggleHasRule, { n, off: true });
          report(name, "without-costly", { costly: costly.length, ...(await insertion(page, "button", 3)) });
          await page.evaluate(toggleHasRule, { n: -1, off: false });
        }

        // Candidate rewrites, each measured alone over the pane with every costly :has() rule
        // taken out (their costs overlap, so one is only seen without the others).
        if (process.env.PANE_HAS_CANDIDATES === "1") {
          const rules = (await page.evaluate(listHasRules)) as { selector: string; sheet: string }[];
          const costly = [
            ":where(button",
            "[inert]",
            ".cv-codeblock__header:has(",
            ".acpmux-composer-box:has(> .acpmux-chrome-area > .acpmux-composer-inner) > .acpmux-composer-field-menu > *",
            ".acpmux-turnSummary:not([data-turn-revealed])",
          ]
            .map((start) => rules.findIndex((rule) => rule.selector.startsWith(start)))
            .filter((n) => n >= 0);
          for (const n of costly) await page.evaluate(toggleHasRule, { n, off: true });
          const floor = await insertion(page, "button", 3);
          report(name, "candidate-floor", { off: costly.length, ...floor });
          const CHECK = 'input[type="checkbox"], input[type="radio"]';
          const CLICK = 'a[href], button, input, select, textarea, summary, [role="button"]';
          const DISABLED =
            'label:not([for]):has(:is(input, select, textarea):disabled):not(:has(:is(input:not([type="hidden"]), select, textarea):enabled))';
          const candidates: [string, string][] = [
            ["label-orig", `:where(label:has(${CHECK})) * { cursor: inherit; }`],
            [
              "label-child-arg",
              `:where(label:has(> input[type="checkbox"], > input[type="radio"])) * { cursor: inherit; }`,
            ],
            ["label-scope", `@scope (label:has(${CHECK})) { :where(:scope *) { cursor: inherit; } }`],
            ["label-not-for", `:where(label:not([for])) * { cursor: inherit; }`],
            ["label-class-right", `:where(label:has(${CHECK})) .x { cursor: inherit; }`],
            ["label-child-star", `:where(label:has(${CHECK})) > * { cursor: inherit; }`],
            ["label-subject", `:where(label:has(${CHECK})) { cursor: pointer; }`],
            ["disabled-orig", `${DISABLED} :not(:is(${CLICK}), :is(${CLICK}) *) { cursor: default !important; }`],
            ["disabled-subject", `${DISABLED} { cursor: default !important; }`],
            [
              "disabled-scope",
              `@scope (${DISABLED}) { :scope :not(:is(${CLICK}), :is(${CLICK}) *) { cursor: default !important; } }`,
            ],
            [
              "pr-not",
              `.acpmux-assistant:not(:hover) .cv-reply-actions:has(> .acpmux-pr-dock) > :not(.acpmux-pr-dock) { opacity: 0; }`,
            ],
            [
              "pr-attr",
              `.acpmux-assistant:not(:hover) .cv-reply-actions[data-pr-dock] > :not(.acpmux-pr-dock) { opacity: 0; }`,
            ],
            [
              "composer-star",
              `.acpmux-composer-box:has(> .acpmux-chrome-area > .acpmux-composer-inner) > .acpmux-composer-field-menu > * { grid-column: 2; }`,
            ],
            [
              "composer-attr",
              `.acpmux-composer-box[data-composer-grid] > .acpmux-composer-field-menu > * { grid-column: 2; }`,
            ],
            [
              "codeblock-span",
              `.cv-codeblock__header:has(.acpmux-pr-dock) > span:not(.cv-codeblock__actions) { min-width: 0; }`,
            ],
          ];
          for (const [label, css] of candidates) {
            await page.evaluate((css) => {
              const style = document.createElement("style");
              style.id = "pane-has-candidate";
              style.textContent = css;
              document.head.append(style);
            }, css);
            const after = await insertion(page, "button", 3);
            await page.evaluate(() => document.getElementById("pane-has-candidate")?.remove());
            report(name, "candidate", { label, floor: floor.elements, after: after.elements, ms: after.ms });
          }
          await page.evaluate(toggleHasRule, { n: -1, off: false });
        }
        expect(true).toBe(true);
      } finally {
        await page.close();
      }
    });
  }
});
