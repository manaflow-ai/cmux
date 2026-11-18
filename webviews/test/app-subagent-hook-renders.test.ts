// cmux-web-test-timeout: 300
// l10n-allow-file: test fixture names, not shipped UI.
// Opening a subagent's view from the chat and going back draws the pane no more than it did before
// the pane's subagent handling left App for its own hook (subagents/useSubagents.ts): the
// "Open <subagent>" chip goes through `showSubagent` (no native host here, so the view opens in
// place), Escape and the "Subagent of" pill's × go back through `navigateSubagent`.
//
// The page is the pane's dev entry with the in-page mock daemon and the two finished subagents of
// the "subagent-report" fixture. Real Chromium and WebKit; CI fails the file when one cannot launch.
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, webkit, type Browser, type BrowserType, type Page } from "playwright";
import { probeEngineOrSkip, requireBrowserLane } from "./support/requireBrowserLane";
import { warmViteServer } from "./support/warmDevServer";
import { COMPOSER_EDITOR } from "../src/agent-session/acpmux/composerSelectors";

const OPEN_CHIP = "button.cv-agent-tag.cv-subagent-started__lead";
const SUBAGENT_OF = ".cv-subagent-of";
const SUBAGENT_OF_CLOSE = "button.cv-subagent-of__close";
const ROUNDS = 3;
/// Pane renders over the rounds below on the base this was measured on (b4933ba8547, before the
/// hook): 13 in Chromium and in WebKit, run after run. More means the move redraws the pane.
const PANE_RENDERS_MAX = 13;

await requireBrowserLane("app-subagent-hook-renders.test.ts", async () => {
  setDefaultTimeout(280_000);
  const { createServer } = await import("vite");
  const webviews = path.resolve(import.meta.dir, "..");
  let vite: Awaited<ReturnType<typeof createServer>> | undefined;
  let base = "";
  beforeAll(async () => {
    vite = await createServer({
      configFile: path.join(webviews, "vite.config.acpmux-pane.mjs"),
      server: { port: 0, host: "127.0.0.1", strictPort: false, watch: { ignored: () => true } },
      logLevel: "error",
    });
    await vite.listen();
    await warmViteServer(vite, "/?mock");
    const { port } = vite.httpServer!.address() as { port: number };
    base = `http://127.0.0.1:${port}`;
  });
  afterAll(async () => {
    await vite?.close();
  });

  const twoFrames = () =>
    new Promise<void>((resolve) => requestAnimationFrame(() => requestAnimationFrame(() => resolve())));

  async function openPane(browser: Browser): Promise<Page> {
    const page = await browser.newPage({ viewport: { width: 900, height: 760 } });
    await page.goto(`${base}/?mock`);
    await page.waitForFunction(() => "cmuxAcpmuxDebug" in window, null, { timeout: 60_000 });
    await page.evaluate(() => (window as any).cmuxAcpmuxDebug.seedRows(0, "subagent-report"));
    await page.locator(OPEN_CHIP).waitFor({ state: "visible", timeout: 30_000 });
    await page.locator(COMPOSER_EDITOR).waitFor({ state: "visible", timeout: 30_000 });
    await page.evaluate(twoFrames);
    return page;
  }

  const engines: [string, BrowserType][] = [
    ["chromium", chromium],
    ["webkit", webkit],
  ];
  for (const [name, engine] of engines) {
    if (!(await probeEngineOrSkip(`app-subagent-hook-renders (${name})`, name, engine))) continue;
    describe(name, () => {
      let browser: Browser | undefined;
      beforeAll(async () => {
        browser = await engine.launch({ headless: true });
      });
      afterAll(async () => {
        await browser?.close();
      });

      test("opening a subagent's view and going back draws the pane no more than before", async () => {
        const page = await openPane(browser!);
        await page.evaluate(() => (window as any).cmuxAcpmuxDebug.renders());
        const chipName = await page.locator(OPEN_CHIP).innerText();
        const pills: string[] = [];
        for (let round = 0; round < ROUNDS; round += 1) {
          await page.locator(OPEN_CHIP).click();
          await page.locator(SUBAGENT_OF).waitFor({ state: "visible" });
          pills.push(await page.locator(SUBAGENT_OF).innerText());
          await page.evaluate(twoFrames);
          // Back to the chat: Escape on even rounds, the pill's × on odd ones.
          if (round % 2 === 0) await page.keyboard.press("Escape");
          else await page.locator(SUBAGENT_OF_CLOSE).click();
          await page.locator(SUBAGENT_OF).waitFor({ state: "detached" });
          await page.locator(OPEN_CHIP).waitFor({ state: "visible" });
          await page.evaluate(twoFrames);
        }
        const renders = (await page.evaluate(() => (window as any).cmuxAcpmuxDebug.renders())) as Record<
          string,
          number
        >;
        const composerBack = await page.locator(COMPOSER_EDITOR).isVisible();
        await page.close();
        console.log(
          `APP-SUBAGENT-HOOK-RENDERS ${JSON.stringify({ engine: name, rounds: ROUNDS, pane: renders.pane ?? 0 })}`,
        );
        // Each round showed the subagent's view, named after the subagent, and came back to the chat.
        expect(pills).toHaveLength(ROUNDS);
        for (const pill of pills) expect(pill, "the Subagent of pill names the subagent").toContain(chipName);
        expect(composerBack, "the chat's composer is back").toBe(true);
        expect(renders.pane ?? 0, "pane renders").toBeGreaterThan(0);
        expect(renders.pane ?? 0, "pane renders").toBeLessThanOrEqual(PANE_RENDERS_MAX);
      });
    });
  }
});
