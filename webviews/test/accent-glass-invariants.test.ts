// Two standing rules as an invariant over every web gallery stage: the accent is never orange
// (nothing reads the macOS system accent, which is orange when the person picks orange, and no
// accent-bearing color has an orange hue) and glass is never opaque (no `backdrop-filter` surface
// with an alpha-1 fill). test/support/accentGlassScan.ts has the rules; pane-toolbar found a menu
// highlighted in the system accent (2026-10-20), which is what this keeps from coming back.
//
// Each web entry x variant renders in the gallery's component frame on the app's default theme,
// is scanned as it first paints, then twice more after Tab moves the keyboard focus (the focus
// ring is where the system accent leaks most). A finding fails the test unless its key is in
// test/accent-glass-baseline.txt, the known violations each waiting on a fix (owner noted there);
// a baseline line no stage reports any more is printed so it can be dropped.
//
// Real Chromium from Playwright; CI fails the file when it cannot launch (requireBrowserLane).
import { afterAll, beforeAll, expect, setDefaultTimeout, test } from "bun:test";
import fs from "node:fs";
import path from "node:path";
import { chromium, type Browser } from "playwright";
import { loadEntrySources } from "../scripts/gallery/entries";
import { findingKey, scanStage, type Finding } from "./support/accentGlassScan";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { warmViteServer } from "./support/warmDevServer";

await requireBrowserLane("accent-glass-invariants.test.ts", async () => {
  setDefaultTimeout(1_800_000);
  const webviews = path.resolve(import.meta.dir, "..");
  const baselineFile = path.join(import.meta.dir, "accent-glass-baseline.txt");
  const baseline = new Set(
    fs
      .readFileSync(baselineFile, "utf8")
      .split("\n")
      .map((line) => line.replace(/\s+#.*$/, "").trim())
      .filter((line) => line && !line.startsWith("#")),
  );
  const stages = (await loadEntrySources())
    .filter(({ entry }) => entry.host !== "native")
    .flatMap(({ entry, path: source }) =>
      Object.keys(entry.variants).map((variant) => ({ entry: entry.id, variant, source })),
    );

  const { createServer } = await import("vite");
  let vite: Awaited<ReturnType<typeof createServer>> | undefined;
  let browser: Browser | undefined;
  beforeAll(async () => {
    vite = await createServer({
      configFile: path.join(webviews, "vite.config.gallery-dev.ts"),
      server: { port: 0, host: "127.0.0.1", strictPort: false },
      logLevel: "error",
    });
    await vite.listen();
    await warmViteServer(vite, "/gallery/frame.html");
    browser = await chromium.launch({ headless: true });
  });
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });

  type Scanned = { stage: string; findings: Finding[] } | { stage: string; error: string };

  const scan = async (stage: (typeof stages)[number]): Promise<Scanned> => {
    const name = `${stage.entry}/${stage.variant}`;
    const port = (vite!.httpServer!.address() as { port: number }).port;
    const query = new URLSearchParams({
      entry: stage.entry,
      variant: stage.variant,
      entryPath: stage.source,
      frame: "component",
    });
    const page = await browser!.newPage({ viewport: { width: 760, height: 900 } });
    try {
      await page.goto(`http://127.0.0.1:${port}/gallery/frame.html?${query}`);
      await page.waitForFunction(() => document.documentElement.dataset.galleryReady, undefined, {
        timeout: 60_000,
      });
      if ((await page.evaluate(() => document.documentElement.dataset.galleryReady)) !== "1")
        return { stage: name, error: "the stage did not render" };
      const findings = await page.evaluate(scanStage, false);
      for (let step = 0; step < 2; step++) {
        await page.keyboard.press("Tab");
        findings.push(...(await page.evaluate(scanStage, true)));
      }
      return { stage: name, findings };
    } catch (error) {
      return { stage: name, error: String(error).split("\n")[0]! };
    } finally {
      await page.close();
    }
  };

  test(`no orange or system accent and no opaque glass on ${stages.length} gallery stages`, async () => {
    const results: Scanned[] = [];
    const queue = [...stages];
    await Promise.all(
      Array.from({ length: 6 }, async () => {
        for (let stage = queue.shift(); stage; stage = queue.shift()) results.push(await scan(stage));
      }),
    );

    const fresh: string[] = [];
    const reported = new Set<string>();
    for (const result of results.sort((a, b) => a.stage.localeCompare(b.stage))) {
      if ("error" in result) {
        // Rendering is gallery-coverage's job; this test only says what it could not scan.
        console.warn(`accent-glass: not scanned ${result.stage}: ${result.error}`);
        continue;
      }
      for (const finding of result.findings) {
        const key = findingKey(result.stage, finding);
        if (reported.has(key)) continue;
        reported.add(key);
        if (baseline.has(key)) continue;
        fresh.push(`${key}  (${finding.detail})`);
      }
    }
    for (const key of baseline)
      if (!reported.has(key)) console.warn(`accent-glass: baseline line no longer found, drop it: ${key}`);
    console.log(
      `accent-glass: scanned ${results.filter((result) => !("error" in result)).length} of ${stages.length} stages, ${reported.size} findings, ${fresh.length} new`,
    );
    if (fresh.length) console.log(`accent-glass findings:\n${fresh.join("\n")}`);
    expect(fresh).toEqual([]);
  });
});
