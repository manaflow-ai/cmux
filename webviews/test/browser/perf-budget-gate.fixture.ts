// Run only by perf-budget-gate.browser.test.ts, in a `bun test` of its own (the suite runs *.test.*
// files, and this is not one): mounts one perf-budgets.harness.tsx case (`PERF_GATE_CASE`) through
// the webviews dev server and asserts nothing about the budgets, so the browser test gate
// (support/perfBudgetGate.ts) alone decides whether this file passes.
import { afterAll, beforeAll, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser } from "playwright";
import { warmViteServer } from "../support/warmDevServer";

setDefaultTimeout(120_000);
const PAGE = "/test/browser/perf-budgets.html";
const webviews = path.resolve(import.meta.dir, "../..");
const { createServer } = await import("vite");
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

test(`mounts ${process.env.PERF_GATE_CASE}`, async () => {
  const { port } = vite!.httpServer!.address() as { port: number };
  const page = await browser!.newPage({ viewport: { width: 900, height: 900 } });
  await page.goto(`http://127.0.0.1:${port}${PAGE}?case=${process.env.PERF_GATE_CASE}`);
  await page.waitForFunction(() => "__perfCase" in window);
  await page.evaluate(() => (window as unknown as { __perfCase: { done: Promise<void> } }).__perfCase.done);
});
