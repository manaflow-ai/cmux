// The accent and glass invariants over every web gallery stage, split into parts
// (accent-glass-invariants-N.test.ts). Two standing rules: the accent is never orange
// (nothing reads the macOS system accent, which is orange when the person picks orange, and no
// accent-bearing color has an orange hue) and glass is never opaque (no `backdrop-filter` surface
// with an alpha-1 fill). test/support/accentGlassScan.ts has the rules; pane-toolbar found a menu
// highlighted in the system accent (2026-10-20), which is what this keeps from coming back.
//
// Each web entry x variant renders in the gallery's component frame on the app's default theme
// (case a: no orange anywhere), then on each theme schemas/theme/orange-accent-allowlist.json
// names (case b: the person picked an orange theme, so the orange-hue rule is off; the system
// accent and glass rules still hold). Each stage
// is scanned as it first paints, then twice more after Tab moves the keyboard focus (the focus
// ring is where the system accent leaks most). A finding fails the test unless its key is in
// test/accent-glass-baseline.txt, the known violations each waiting on a fix (owner noted there);
// a baseline line no stage of the part reports any more is printed so it can be dropped.
//
// Why parts: one file for all 2,542 stages took about 9 minutes alone and hit its 900 s limit on a
// busy shard, and a timed-out file that long gets no retry before the step's retry deadline, so it
// was charged as a new red to pull requests that never touched it (2026-10-30, runs 41079754472,
// 41076022470, 41048809560). Each part scans every `parts`-th stage of the sorted list.
//
// Real Chromium from Playwright; CI fails the file when it cannot launch (requireBrowserLane).
// gallery-frame-every-entry: it scans every web entry, so it warms the frame for all of them once;
// each stage still passes its own entryPath.
import { afterAll, beforeAll, expect, setDefaultTimeout, test } from "bun:test";
import fs from "node:fs";
import path from "node:path";
import { chromium, type Browser, type Page } from "playwright";
import { loadEntrySources } from "../../scripts/gallery/entries";
import { findingKey, scanStage, type Finding } from "./accentGlassScan";
import { requireBrowserLane } from "./requireBrowserLane";
import { warmViteServer } from "./warmDevServer";

export type AccentGlassPart = {
  /** The part's test file name, for requireBrowserLane. */
  file: string;
  /** One-based. */
  part: number;
  parts: number;
  /** The gallery's dev server config, named in the part's own file so the runner sees a dev server file. */
  viteConfig: string;
};

type Stage = { entry: string; variant: string; source: string; theme: string | undefined };
const stageName = (stage: Stage): string => `${stage.entry}/${stage.variant}${stage.theme ? `@${stage.theme}` : ""}`;

export async function accentGlassInvariants({ file, part, parts, viteConfig }: AccentGlassPart): Promise<void> {
  await requireBrowserLane(file, async () => {
    setDefaultTimeout(450_000);
    const webviews = path.resolve(import.meta.dir, "../..");
    const baselineFile = path.join(webviews, "test/accent-glass-baseline.txt");
    const baseline = new Set(
      fs
        .readFileSync(baselineFile, "utf8")
        .split("\n")
        .map((line) => line.replace(/\s+#.*$/, "").trim())
        .filter((line) => line && !line.startsWith("#")),
    );
    // Case (b): each theme the allowlist names may show its own orange accent. One theme of each
    // entry (its dark one) runs every stage again; the default theme's run is case (a).
    const allowlist = JSON.parse(
      fs.readFileSync(path.join(webviews, "../schemas/theme/orange-accent-allowlist.json"), "utf8"),
    ) as { allowed: { name: string; themes: string[] }[] };
    const themes: (string | undefined)[] = [undefined, ...allowlist.allowed.map((entry) => entry.themes[0]!)];
    const orangeThemes = new Set(allowlist.allowed.flatMap((entry) => entry.themes));
    const everyStage = (await loadEntrySources())
      .filter(({ entry }) => entry.host !== "native")
      .flatMap(({ entry, path: source }) =>
        Object.keys(entry.variants).flatMap((variant, index) =>
          // Case (b) only changes the orange rule, so each entry's first variant is enough there.
          themes
            .filter((theme) => theme === undefined || index === 0)
            .map((theme) => ({ entry: entry.id, variant, source, theme })),
        ),
      )
      .sort((a, b) => stageName(a).localeCompare(stageName(b)));
    // This part's share: every `parts`-th stage of the sorted list, so each part gets a mix of entries.
    const stages = everyStage.filter((_, index) => index % parts === part - 1);
    const mine = new Set(stages.map(stageName));
    // A baseline key is `<stage> <rule> <element>`, and a stage name may hold spaces (a theme such as `Clay Orange`):
    // its stage is the longest stage name it starts with. A key no stage has any more is part 1's to report.
    const names = everyStage.map(stageName).sort((a, b) => b.length - a.length);
    const ownedHere = (key: string): boolean => {
      const stage = names.find((name) => key.startsWith(`${name} `));
      return stage === undefined ? part === 1 : mine.has(stage);
    };

    const { createServer } = await import("vite");
    let vite: Awaited<ReturnType<typeof createServer>> | undefined;
    let browser: Browser | undefined;
    beforeAll(async () => {
      vite = await createServer({
        configFile: path.join(webviews, viteConfig),
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

    const scan = async (page: Page, stage: (typeof stages)[number]): Promise<Scanned> => {
      const name = stageName(stage);
      const orangeAllowed = stage.theme !== undefined && orangeThemes.has(stage.theme);
      const port = (vite!.httpServer!.address() as { port: number }).port;
      const query = new URLSearchParams({
        entry: stage.entry,
        variant: stage.variant,
        entryPath: stage.source,
        frame: "component",
        ...(stage.theme ? { theme: stage.theme } : {}),
      });
      try {
        await page.goto(`http://127.0.0.1:${port}/gallery/frame.html?${query}`);
        await page.waitForFunction(() => document.documentElement.dataset.galleryReady, undefined, {
          timeout: 20_000,
        });
        if ((await page.evaluate(() => document.documentElement.dataset.galleryReady)) !== "1")
          return { stage: name, error: "the stage did not render" };
        const findings = await page.evaluate(scanStage, { focusedOnly: false, orangeAllowed });
        for (let step = 0; step < 2; step++) {
          await page.keyboard.press("Tab");
          findings.push(...(await page.evaluate(scanStage, { focusedOnly: true, orangeAllowed })));
        }
        return { stage: name, findings };
      } catch (error) {
        return { stage: name, error: String(error).split("\n")[0]! };
      }
    };

    // A constant title: the stage count in it made every PR that adds a stage look like a new failing test.
    test(`no orange or system accent and no opaque glass on the gallery stages (part ${part} of ${parts})`, async () => {
      const results: Scanned[] = [];
      const queue = [...stages];
      await Promise.all(
        // One page per worker, reused from stage to stage: a fresh page per stage cost more than the scan.
        Array.from({ length: 8 }, async () => {
          const open = () => browser!.newPage({ viewport: { width: 760, height: 900 } });
          let page = await open();
          for (let stage = queue.shift(); stage; stage = queue.shift()) {
            const result = await scan(page, stage);
            results.push(result);
            // A stage that failed may leave its page stuck or crashed: the next stage gets a new one.
            if ("error" in result) {
              await page.close().catch(() => {});
              page = await open();
            }
            if (results.length % 50 === 0)
              console.log(
                `accent-glass: ${results.length}/${stages.length} stages, ${Math.round(performance.now() / 1000)}s`,
              );
          }
          await page.close();
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
      // A baseline line belongs to the part that scans its stage.
      for (const key of baseline)
        if (ownedHere(key) && !reported.has(key))
          console.warn(`accent-glass: baseline line no longer found, drop it: ${key}`);
      console.log(
        `accent-glass: scanned ${results.filter((result) => !("error" in result)).length} of ${stages.length} stages, ${reported.size} findings, ${fresh.length} new`,
      );
      if (fresh.length) console.log(`accent-glass findings:\n${fresh.join("\n")}`);
      expect(fresh, `new accent-glass findings across ${stages.length} gallery stages`).toEqual([]);
      // A scan that reached nothing proves nothing: most stages, and each allowlisted theme, scanned.
      const scanned = results.filter((result) => !("error" in result));
      expect(scanned.length, `stages scanned of ${stages.length}`).toBeGreaterThan(stages.length * 0.9);
      for (const theme of orangeThemes)
        if (themes.includes(theme) && stages.some((stage) => stage.theme === theme))
          expect(
            scanned.some((result) => result.stage.endsWith(`@${theme}`)),
            `${theme} scanned`,
          ).toBe(true);
    });
  });
}
