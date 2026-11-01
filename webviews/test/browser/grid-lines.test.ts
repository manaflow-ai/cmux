// cmux-web-test-timeout: 600
// Discovered by run-webviews-tests.sh (browser import + gallery Vite config);
// tests/test-execution.toml registers Python tests only. No duplicate browser registry.
import { afterAll, beforeAll, expect, setDefaultTimeout, test } from "bun:test";
import { mkdir, writeFile } from "node:fs/promises";
import path from "node:path";
import { chromium, type Browser } from "playwright";
import { galleryFrame, warmGalleryFrame } from "../support/galleryFrame";
import { probeEngineOrSkip, requireBrowserLane } from "../support/requireBrowserLane";
import { measureGridLines, type GridResult } from "../support/gridLines";
import { gridScenes } from "../support/gridScenes";

await requireBrowserLane("browser/grid-lines.test.ts", async () => {
  if (!(await probeEngineOrSkip("grid-lines", "chromium", chromium))) return;
  setDefaultTimeout(180_000);
  const tolerance = 0.5;
  const webviews = path.resolve(import.meta.dir, "../..");
  const artifact = path.resolve(process.env.CMUX_GRID_LINES_JSON ?? path.join(webviews, "artifacts/grid-lines.json"));
  const { createServer } = await import("vite");
  let vite: Awaited<ReturnType<typeof createServer>> | undefined;
  let browser: Browser | undefined;
  const fixtureErrors: { surface: string; width: number; scheme: string; error: string }[] = [];
  const records: {
    surface: string;
    level: string;
    entry: string;
    variant: string;
    root: string;
    width: number;
    scheme: string;
    lines: GridResult[];
  }[] = [];
  const problem = (line: GridResult) => !!line.diagnostic || line.delta === null || Math.abs(line.delta) > tolerance;
  const number = (n: number | null) => (n === null ? "unavailable" : n.toFixed(2));
  const escape = (s: string) => s.replaceAll("%", "%25").replaceAll("\r", "%0D").replaceAll("\n", "%0A");
  beforeAll(async () => {
    vite = await createServer({
      configFile: path.join(webviews, "vite.config.gallery-dev.ts"),
      server: { host: "127.0.0.1", port: 0 },
      logLevel: "error",
    });
    await vite.listen();
    browser = await chromium.launch({ headless: true });
    await warmGalleryFrame(vite, "agent-pane.composer-row", {
      browser,
      params: { variant: "claude-auto" },
    });
  });
  afterAll(async () => {
    try {
      await mkdir(path.dirname(artifact), { recursive: true });
      const report = { tolerance, measuredAt: new Date().toISOString(), records, fixtureErrors };
      await writeFile(artifact, JSON.stringify(report, null, 2) + "\n");
      console.log(
        "| Surface / variant | Theme / width | Level | Line | Expected | Measured | Delta | Diagnostic |\n|---|---|---|---|---:|---:|---:|---|",
      );
      const cell = (s: string) => s.replaceAll("|", "\\|").replaceAll("\n", " ");
      for (const r of records)
        for (const line of r.lines)
          console.log(
            `| ${r.surface} / ${r.variant} | ${r.scheme} / ${r.width} | ${r.level} | ${line.line} | ${number(line.expected)} | ${number(line.actual)} | ${number(line.delta)} | ${cell(line.diagnostic ?? "")} |`,
          );
      console.log(`grid-lines JSON: ${artifact}`);
    } finally {
      try {
        await browser?.close();
      } finally {
        await vite?.close();
      }
    }
  });

  for (const scene of gridScenes)
    for (const width of [720, 420])
      for (const scheme of ["light", "dark"])
        test(`${scene.surface}/${scene.variant} (${scene.root}): ${scheme}, ${width}px [${scene.level}]`, async () => {
          const page = await browser!.newPage({
            viewport: { width, height: 900 },
            colorScheme: scheme as "light" | "dark",
          });
          let lines: GridResult[];
          let clippedHeadings: (string | null)[] = [];
          try {
            const port = (vite!.httpServer!.address() as { port: number }).port;
            await page.goto(
              `http://127.0.0.1:${port}${galleryFrame(scene.entry, { ...scene.params, variant: scene.variant, theme: scheme === "light" ? "Apple System Colors Light" : "Apple System Colors" })}`,
            );
            await page.waitForFunction(() => document.documentElement.dataset.galleryReady, undefined, {
              timeout: 90_000,
            });
            const ready = await page.evaluate(() => ({
              state: document.documentElement.dataset.galleryReady,
              error: document.body.textContent,
            }));
            if (ready.state !== "1") throw new Error(`gallery did not mount: ${ready.error}`);
            await page.evaluate(() => document.fonts.ready);
            await page.evaluate(
              () => new Promise<void>((resolve) => requestAnimationFrame(() => requestAnimationFrame(() => resolve()))),
            );
            lines = await page.evaluate(measureGridLines, scene);
            if (scene.surface === "session-info") {
              clippedHeadings = await page
                .locator(".acpmux-session-info-section__title")
                .evaluateAll((titles) =>
                  titles.filter((title) => title.scrollWidth > title.clientWidth + 1).map((title) => title.textContent),
                );
            }
            if (process.env.CMUX_GRID_CAPTURE_DIR && scene.surface === "session-info") {
              const directory = path.resolve(process.env.CMUX_GRID_CAPTURE_DIR);
              await mkdir(directory, { recursive: true });
              // Capture the real gallery DOM, expanded and tall enough to show every section.
              await page.setViewportSize({ width, height: 2400 });
              await page.screenshot({
                path: path.join(directory, `${scene.variant}-${scheme}-${width}.png`),
                fullPage: true,
              });
            }
          } catch (error) {
            fixtureErrors.push({ surface: scene.surface, width, scheme, error: String(error) });
            throw error;
          } finally {
            await page.close();
          }
          const record = {
            surface: scene.surface,
            level: scene.level,
            entry: scene.entry,
            variant: scene.variant,
            root: scene.root,
            width,
            scheme,
            lines,
          };
          records.push(record);
          // Emit before assertions so failed scenes and truncated runs retain measurements.
          console.log(
            `GRID_LINES_JSON=${JSON.stringify({ tolerance, measuredAt: new Date().toISOString(), records: [record] })}`,
          );
          for (const line of lines.filter(problem)) {
            const detail = `${line.line} expected ${number(line.expected)} got ${number(line.actual)} (delta ${number(line.delta)}); ${scheme}/${width}${line.diagnostic ? `; ${line.diagnostic}` : ""}`;
            console.warn(
              `::${scene.level === "fail" ? "error" : "warning"} title=grid-lines ${escape(scene.surface)}::${escape(detail)}`,
            );
          }
          expect(clippedHeadings, "section names stay readable before their status counts").toEqual([]);
          expect(lines.filter((line) => line.coverageFailure)).toEqual([]);
          if (scene.level === "fail") expect(lines.filter(problem)).toEqual([]);
        });
});
