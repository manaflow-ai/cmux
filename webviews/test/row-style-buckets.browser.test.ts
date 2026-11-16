// cmux-web-test-timeout: 600
// How many style rules Chromium tries on each element of a transcript row as it mounts (its selector
// stats, `disabled-by-default-blink.debug`): the rows a page of older history mounts while the reader
// scrolls up pay this per element, thousands of elements a frame (Leo, 2026-11-16: "how about speeding
// up the scrolling up of chats?", "as in i scroll up and it loads the stuff"). A rule whose subject
// is an `:is()`/`:where()` of several has no class, tag or attribute of its own for the engine to file
// it under, so every element styled tried it; the build lists such a rule once per alternative
// (scripts/postcss/subjectBuckets.mjs, test/subject-buckets.test.ts).
import { afterAll, beforeAll, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser, type Page } from "playwright";
import { probeEngineOrSkip, requireBrowserLane } from "./support/requireBrowserLane";
import { warmViteServer } from "./support/warmDevServer";

/// Rules tried per element styled as rows mount, at most. Before the split: 313 (red); after: see the
/// commit that set it.
const MAX_TRIED_PER_ELEMENT = Number(process.env.ROW_STYLE_MAX_TRIED ?? 260);

await requireBrowserLane("row-style-buckets.browser.test.ts", async () => {
  if (!(await probeEngineOrSkip("row style buckets", "chromium", chromium))) return;
  setDefaultTimeout(300_000);
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

  /// Mounts copies of the drawn rows (as a page of older history mounts new rows) and returns the
  /// elements styled and the rules tried on them, from the trace.
  async function mountCopies(page: Page): Promise<{ elements: number; tried: number }> {
    await page.evaluate(twoFrames);
    await browser!.startTracing(page, { categories: ["devtools.timeline", "disabled-by-default-blink.debug"] });
    await page.evaluate(async () => {
      const rows = [...document.querySelectorAll<HTMLElement>(".acpmux-scroll .acpmux-row")];
      const host = rows[0]!.parentElement!;
      for (const row of rows) {
        const copy = row.cloneNode(true) as HTMLElement;
        copy.removeAttribute("id");
        copy.dataset.styleProbe = "";
        host.append(copy);
      }
      await new Promise((resolve) => requestAnimationFrame(() => requestAnimationFrame(resolve)));
    });
    const raw = JSON.parse((await browser!.stopTracing()).toString()) as {
      traceEvents: { name: string; ph: string; args?: any }[];
    };
    await page.evaluate(() => document.querySelectorAll("[data-style-probe]").forEach((node) => node.remove()));
    let elements = 0;
    let tried = 0;
    for (const event of raw.traceEvents) {
      if (event.name === "UpdateLayoutTree" && (event.ph === "X" || event.ph === "E"))
        elements += Number(event.args?.elementCount ?? event.args?.data?.elementCount ?? 0);
      if (event.name === "SelectorStats")
        for (const each of event.args?.selector_stats?.selector_timings ?? [])
          tried += Number(each.match_attempts ?? 0);
    }
    return { elements, tried };
  }

  test("each element of a mounted row tries no rule filed under no class, tag or attribute", async () => {
    const page = await browser!.newPage({ viewport: { width: 1100, height: 800 } });
    try {
      await page.goto(`${base}/test/latency/flows.html?mock&turns=3000&resident`);
      await page.waitForFunction(() => document.documentElement.dataset.latencyFlowsReady === "true", undefined, {
        timeout: 200_000,
      });
      const perElement: number[] = [];
      let elements = 0;
      for (let run = 0; run < 5; run += 1) {
        const styled = await mountCopies(page);
        elements = styled.elements;
        perElement.push(styled.tried / Math.max(1, styled.elements));
      }
      const median = [...perElement].sort((a, b) => a - b)[2]!;
      console.log(
        `ROW-STYLE ${JSON.stringify({ elementsStyled: elements, rulesTriedPerElement: Math.round(median), limit: MAX_TRIED_PER_ELEMENT })}`,
      );
      expect(elements).toBeGreaterThan(100);
      expect(median).toBeLessThanOrEqual(MAX_TRIED_PER_ELEMENT);
    } finally {
      await page.close();
    }
  });
});
