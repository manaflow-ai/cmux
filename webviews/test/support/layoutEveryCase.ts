// l10n-allow-file: test names, not shipped UI.
// Every case of the layout-shift case space (src/agent-session/acpmux/sim/layoutCases.ts), played in
// Chromium through the chat simulator's page with motion on (browser/layoutCaseRunner.ts): each content
// kind (streaming text, tables, images, mermaid, code, math, RTL, emoji, very long tokens, subagents,
// compaction, empty, huge) crossed with each perturbation (resize, split, zoom, font and theme swaps, the
// reader parked while it streams, tab and workspace switches, wheel and resize bursts, reconnect replay,
// re-delivery), plus a width sweep. Every move over 1 px the reader's own act did not cause is a flag.
//
// Leo, 2026-11-22: "EVERY POSSIBLE CASE, NO MATTER HOW WILD". The gate is a ratchet on which cases shift:
// a case test/layout-every-case-baseline.json does not list must not flag at all, so a new shift fails now,
// and the list shrinks to empty as fixes land (a listed case that comes back clean is printed, to drop).
// It is not a ratchet on how many flags a listed case has: that count moves run to run with frame timing
// (huge/zoom flagged 24, 27 and 30 times, table/zoom 36, 41 and 44, in three runs of the same tree), while
// whether a case flags at all held in every rerun. The listed counts are one run's, for reading.
//
//   CMUX_BROWSER_TESTS=1 bun test test/layout-every-case-browser-1.test.ts   (one part; each plays every PARTS-th case)
//   LAYOUT_CASES=basic/none,table/resize   pick cases within the part (a prefix ending in / takes a content kind)
//   LAYOUT_CASES_OUT=FILE (or $FAST_CHECKS_OUT/layout-every-case-N.json) writes the part's results as JSON
//   LAYOUT_CASES_REPORT=1                  report only, never fail (to refresh the baseline)
//
// Why parts: all 256 runs (240 cases and 16 planted-jump controls) took 1397 s in one Chromium on an 8-core
// lane VM, past the runner's 900 s cap a file can declare (scripts/ci/run-webviews-tests.sh), and CI's shards
// run on 4 (at times 2) vCPU. So PARTS files (layout-every-case-browser-N.test.ts), each playing every
// PARTS-th case of layoutCases() and every PARTS-th planted-jump control, each alone on its shard
// (`// cmux-web-test-alone`): the flags are read frame by frame with motion on, and a busy CPU moves frames.
import { afterAll, beforeAll, expect, setDefaultTimeout, test } from "bun:test";
import { readFileSync, writeFileSync } from "node:fs";
import path from "node:path";
import type { Browser, Page } from "playwright";
import { CONTROL, layoutCases, type LayoutCaseResult } from "../../src/agent-session/acpmux/sim/layoutCases";
import { requireBrowserLane } from "./requireBrowserLane";
import { warmViteServer } from "./warmDevServer";

/** The parts the case space is split into; layout-every-case-browser-1..PARTS.test.ts each run one. */
export const PARTS = 12;

export async function layoutEveryCase({ file, part }: { file: string; part: number }): Promise<void> {
  await requireBrowserLane(file, async () => {
    const PAGE = "/test/browser/chat-sim.html";
    setDefaultTimeout(600_000);
    const { createServer } = await import("vite");
    const { chromium } = await import("playwright");
    const webviews = path.resolve(import.meta.dir, "../..");
    const baseline = JSON.parse(readFileSync(path.join(webviews, "test/layout-every-case-baseline.json"), "utf8")) as {
      flags: Record<string, number>;
    };
    let vite: Awaited<ReturnType<typeof createServer>> | undefined;
    let browser: Browser | undefined;
    let page: Page | undefined;
    beforeAll(async () => {
      vite = await createServer({
        root: webviews,
        configFile: path.join(webviews, "vite.config.ts"),
        mode: "production",
        define: { "process.env.NODE_ENV": JSON.stringify("production") },
        cacheDir: path.join(webviews, "node_modules/.vite-chat-sim"),
        server: { port: 0, host: "127.0.0.1", strictPort: false },
        logLevel: "error",
      });
      await vite.listen();
      await warmViteServer(vite, PAGE, { timeoutMs: 400_000 });
      const { port } = vite.httpServer!.address() as { port: number };
      browser = await chromium.launch({ headless: true });
      page = await browser.newPage({ viewport: { width: 1400, height: 1000 } });
      page.on("pageerror", (error) => console.error(`layout-every-case page: ${error.message}`));
      await page.goto(`http://127.0.0.1:${port}${PAGE}`);
      await page.waitForFunction(() => "__chatSim" in window);
    });

    const picks = process.env.LAYOUT_CASES?.split(",").filter(Boolean);
    // Every PARTS-th case, and every PARTS-th planted-jump control apart from them, so each part has a control.
    const all = layoutCases();
    const mine = (list: typeof all) => list.filter((_, index) => index % PARTS === part - 1);
    const cases = [
      ...mine(all.filter((spec) => spec.perturbation !== CONTROL)),
      ...mine(all.filter((spec) => spec.perturbation === CONTROL)),
    ].filter(
      (spec) => !picks || picks.some((pick) => (pick.endsWith("/") ? spec.id.startsWith(pick) : spec.id === pick)),
    );
    const results: LayoutCaseResult[] = [];
    const out =
      process.env.LAYOUT_CASES_OUT ??
      (process.env.FAST_CHECKS_OUT
        ? path.join(process.env.FAST_CHECKS_OUT, `layout-every-case-${part}.json`)
        : undefined);
    afterAll(async () => {
      await browser?.close();
      await vite?.close();
      const control = results.filter((result) => result.id.split("/")[1] === CONTROL);
      const real = results.filter((result) => !control.includes(result));
      const flagged = real.filter((result) => result.flags.length);
      const total = real.reduce((sum, result) => sum + result.flags.length, 0);
      console.log(
        `layout-every-case part ${part}/${PARTS}: ${real.length} cases run, ${flagged.length} flag a shift, ${total} flags in all, ` +
          `${results.filter((result) => result.error).length} errors; control: ` +
          `${control.filter((result) => result.flags.length).length}/${control.length} planted jumps caught`,
      );
      for (const result of results)
        console.log(
          `  ${result.id.padEnd(40)} steps ${String(result.steps).padStart(3)}  frames ${String(result.frames).padStart(5)}  flags ${String(result.flags.length).padStart(3)}  worst ${result.worst}px${result.error ? `  ERROR ${result.error}` : ""}`,
        );
      if (out)
        writeFileSync(
          out,
          JSON.stringify(
            {
              cases: real.length,
              flagged: flagged.length,
              total,
              control: control.map((result) => [result.id, result.flags.length]),
              results,
            },
            null,
            1,
          ),
        );
    });

    for (const spec of cases)
      test(`layout case ${spec.id}: no unprovoked shift over 1px unless its baseline lists one`, async () => {
        const result = (await page!.evaluate(
          (id) => (window as unknown as { __chatSim: { runCase(id: string): Promise<unknown> } }).__chatSim.runCase(id),
          spec.id,
        )) as LayoutCaseResult;
        results.push(result);
        const listed = spec.id in baseline.flags;
        const allowed = baseline.flags[spec.id] ?? 0;
        if (result.flags.length)
          console.log(
            `${spec.id}: ${result.flags.length} flags (baseline ${allowed}): ` +
              result.flags
                .slice(0, 6)
                .map((flag) => `step ${flag.step} ${flag.kind} ${flag.label} ${flag.px}px`)
                .join("; "),
          );
        if (listed && !result.flags.length)
          console.log(`${spec.id}: no shift now (baseline lists ${allowed}); drop it from the baseline`);
        if (process.env.LAYOUT_CASES_REPORT === "1") return;
        expect(result.error).toBeUndefined();
        // The control plants a jump: a detector that misses it would pass every other case blind.
        if (spec.perturbation === CONTROL) return expect(result.flags.length).toBeGreaterThan(0);
        // A listed case already shifts; one the baseline does not list must not.
        if (!listed)
          expect(result.flags.map((flag) => `step ${flag.step} ${flag.kind} ${flag.label} ${flag.px}px`)).toEqual([]);
      });
  });
}
