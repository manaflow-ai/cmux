// The runtime perf budgets (src/devkit/perfBudgets.ts) fire on each class of past fix reintroduced,
// and stay silent on the fix: a 1000-row list drawn whole (#36132) against VirtualList, a timer per
// row (#28753) against the page clock, a box moved 40 px after paint (#24503, #30543) against the
// same move as a transform, a commit per streamed chunk (#34004, #27911) against one per frame, a
// slow commit and a long frame. The page is served by the webviews dev server (vite.config.ts), so
// the budgets come in the way `cmux live` brings them: its plugin injects them as the first script.
//
// Real Chromium from Playwright (layout-shift and long-animation-frame are Chromium's); CI fails the
// file when it cannot launch (requireBrowserLane).
import { afterAll, beforeAll, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser } from "playwright";
import type { PerfBudgetClass, PerfBudgetViolation } from "../src/devkit/perfBudgets";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { warmViteServer } from "./support/warmDevServer";

await requireBrowserLane("perf-budgets.browser.test.ts", async () => {
  setDefaultTimeout(120_000);
  const { createServer } = await import("vite");
  const webviews = path.resolve(import.meta.dir, "..");
  const PAGE = "/test/browser/perf-budgets.html";
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
    await warmViteServer(vite, PAGE);
    browser = await chromium.launch({ headless: true });
  });
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });

  /** The case's violations in collect mode, and the console warnings in warn mode. */
  async function run(kind: string, mode: "collect" | "warn" = "collect") {
    const { port } = vite!.httpServer!.address() as { port: number };
    const page = await browser!.newPage({ viewport: { width: 900, height: 900 } });
    const warnings: string[] = [];
    page.on("console", (message) => {
      if (message.type() === "warning" && message.text().startsWith("[cmux perf budget]"))
        warnings.push(message.text());
    });
    await page.addInitScript((mode) => {
      (window as unknown as { __cmuxPerfBudgets: unknown }).__cmuxPerfBudgets = { mode };
    }, mode);
    await page.goto(`http://127.0.0.1:${port}${PAGE}?case=${kind}`);
    await page.waitForFunction(() => "__perfCase" in window);
    await page.evaluate(() => (window as unknown as { __perfCase: { done: Promise<void> } }).__perfCase.done);
    // What is still queued (observer entries, the breadth batch), checked now.
    const violations = await page.evaluate(() => {
      const handle = (
        window as unknown as { __cmuxPerfBudgetsHandle?: { flush(): void; violations: PerfBudgetViolation[] } }
      ).__cmuxPerfBudgetsHandle;
      handle?.flush();
      return handle?.violations ?? null;
    });
    await page.close();
    expect(violations).not.toBeNull();
    return { violations: violations!, warnings };
  }
  const kinds = (violations: PerfBudgetViolation[]) =>
    [...new Set(violations.map((violation) => violation.kind))].sort();
  const pair = (bad: string, good: string, kind: PerfBudgetClass) =>
    test(`${kind}: ${bad} fires, ${good} stays silent`, async () => {
      const fired = await run(bad);
      expect(kinds(fired.violations)).toContain(kind);
      const quiet = await run(good);
      expect(quiet.violations.map((violation) => violation.message)).toEqual([]);
    });

  pair("whole-list", "windowed-list", "dom-breadth");
  pair("timer-per-row", "page-clock", "live-intervals");
  pair("layout-move", "transform-move", "layout-shift");
  pair("commit-per-chunk", "commit-per-frame", "react-commit");

  test("react-commit: a 30 ms commit fires and names its root", async () => {
    const { violations } = await run("slow-commit");
    const commit = violations.find((violation) => violation.kind === "react-commit");
    expect(commit?.site).toContain("div#root");
    expect(commit!.measured).toBeGreaterThan(16);
  });

  test("long-frame: 120 ms of script fires", async () => {
    const { violations } = await run("long-frame");
    expect(kinds(violations)).toContain("long-frame");
  });

  test("warn mode: one console warning per site, naming the measure, the budget and the fix", async () => {
    const { warnings } = await run("whole-list", "warn");
    expect(warnings).toHaveLength(1);
    expect(warnings[0]).toContain("dom-breadth: 1000 children over the budget of 300 children at ul.projects");
    expect(warnings[0]).toContain("VirtualList");
    const moved = await run("layout-move", "warn");
    // Every violation is printed once, in order.
    expect(moved.warnings).toEqual(moved.violations.map((violation) => violation.message));
    expect(moved.violations.map((violation) => `${violation.kind} ${violation.measured} ${violation.site}`)).toContain(
      "layout-shift 40 div.moving-box",
    );
  });
});
