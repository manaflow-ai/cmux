// cmux-web-test-timeout: 600
// The list contract (test/support/listContract.ts) over every registered list
// (test/list-contract/<name>.fixture.tsx): each list at 1,000 and 10,000 rows in Chromium, with
// its trace, and in WebKit. A violation fails the file unless test/list-contract/baseline.json
// names it for that list; a baseline entry the list no longer has fails too, so the file only
// shrinks. A WebKit violation's id starts with `webkit:`.
//
// Joining: add test/list-contract/<name>.fixture.tsx (listFixture.ts says what it declares), run
// this file, and fix what it reports rather than adding it to the baseline.
import { afterAll, beforeAll, expect, setDefaultTimeout, test } from "bun:test";
import fs from "node:fs";
import path from "node:path";
import { chromium, webkit, type Browser } from "playwright";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { LIST_SIZES, listReport, listViolations, measureList, type ListMeasure } from "./support/listContract";
import { warmViteServer } from "./support/warmDevServer";

await requireBrowserLane("list-contract.browser.test.ts", async () => {
  const dir = path.join(import.meta.dir, "list-contract");
  const LISTS = fs
    .readdirSync(dir)
    .filter((file) => file.endsWith(".fixture.tsx"))
    .map((file) => file.slice(0, -".fixture.tsx".length))
    .sort();
  const BASELINE: Record<string, string[]> = JSON.parse(fs.readFileSync(path.join(dir, "baseline.json"), "utf8"));

  test("every baseline entry names a registered list", () => {
    expect(Object.keys(BASELINE).filter((list) => !LISTS.includes(list))).toEqual([]);
  });

  setDefaultTimeout(300_000);
  const { createServer } = await import("vite");
  const webviews = path.resolve(import.meta.dir, "..");
  const PAGE = "/test/browser/list-contract.html";
  let vite: Awaited<ReturnType<typeof createServer>> | undefined;
  const browsers: Browser[] = [];
  let base = "";
  beforeAll(async () => {
    vite = await createServer({
      root: webviews,
      configFile: path.join(webviews, "vite.config.ts"),
      server: { port: 0, host: "127.0.0.1", strictPort: false },
      logLevel: "error",
    });
    await vite.listen();
    await warmViteServer(vite, PAGE);
    base = `http://127.0.0.1:${(vite.httpServer!.address() as { port: number }).port}`;
    browsers.push(await chromium.launch({ headless: true }), await webkit.launch({ headless: true }));
  });
  afterAll(async () => {
    for (const browser of browsers) await browser.close();
    await vite?.close();
  });

  const out = process.env.FAST_CHECKS_OUT;
  for (const list of LISTS)
    test(`${list}: mounted rows, row renders and layout per event stay flat from 1,000 to 10,000 rows`, async () => {
      const found = new Map<string, string>();
      for (const browser of browsers) {
        const measures: ListMeasure[] = [];
        for (const n of LIST_SIZES) measures.push(await measureList(browser, base, list, n));
        for (const measure of measures) console.log(listReport(measure));
        if (out)
          fs.appendFileSync(
            path.join(out, "list-contract.jsonl"),
            measures.map((m) => `${JSON.stringify(m)}\n`).join(""),
          );
        const prefix = browser.browserType().name() === "chromium" ? "" : `${browser.browserType().name()}:`;
        for (const [id, why] of listViolations(measures as [ListMeasure, ListMeasure])) found.set(prefix + id, why);
      }
      const known = new Set(BASELINE[list] ?? []);
      const fresh = [...found].filter(([id]) => !known.has(id)).map(([id, why]) => `${id}: ${why}`);
      const fixed = [...known].filter((id) => !found.has(id));
      for (const [id, why] of found) if (known.has(id)) console.log(`LIST-CONTRACT ${list} baseline ${id}: ${why}`);
      expect(fresh, `${list} breaks the list contract (test/support/listContract.ts)`).toEqual([]);
      expect(fixed, `${list} keeps these now: remove them from test/list-contract/baseline.json`).toEqual([]);
    });
});
