// cmux-web-test-timeout: 300
// The folder trust question as the pane draws it, after its state, effects and handlers left App for
// useChatTrust.ts: a new chat's picked folder with no trust answer asks, Trust answers it, and the
// pane draws no more times for that than it did with the trust code inside App.
//
// The page is the pane's dev entry with the in-page mock daemon (`?mock`), whose `acp.trust.get`
// answers "unknown" for a folder no agent has worked in. Real Chromium and WebKit; CI fails the file
// when one cannot launch.
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, webkit, type Browser, type BrowserType } from "playwright";
import { probeEngineOrSkip, requireBrowserLane } from "./support/requireBrowserLane";
import { warmViteServer } from "./support/warmDevServer";
import { COMPOSER_EDITOR } from "../src/agent-session/acpmux/composerSelectors";

await requireBrowserLane("app-trust-hook-renders.test.ts", async () => {
  const FOLDER = "/Users/test/code/untrusted-app";
  const ASK = ".acpmux-trust-ask";
  const TRUST = ".acpmux-trust-ask .acpmux-trust-ask-primary";
  /// The pane's renders on the base with the trust code inside App (lane--composer-react-compiler-bails at
  /// b4933ba8547, lane VM, the same in Chromium and WebKit): from the folder's pick until its question
  /// shows, and from Trust until the question is gone.
  const PANE_ON_BASE = { ask: 6, trust: 2 };
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

  const engines: [string, BrowserType][] = [
    ["chromium", chromium],
    ["webkit", webkit],
  ];
  for (const [name, engine] of engines) {
    if (!(await probeEngineOrSkip(`app-trust-hook-renders (${name})`, name, engine))) continue;
    describe(name, () => {
      let browser: Browser | undefined;
      beforeAll(async () => {
        browser = await engine.launch({ headless: true });
      });
      afterAll(async () => {
        await browser?.close();
      });

      test("a new chat's untrusted folder asks, Trust answers it, and the pane draws no more than before", async () => {
        const page = await browser!.newPage({ viewport: { width: 900, height: 760 } });
        await page.goto(`${base}/?mock`);
        await page.waitForFunction(() => "cmuxAcpmuxDebug" in window, null, { timeout: 60_000 });
        await page.locator(COMPOSER_EDITOR).waitFor({ timeout: 60_000 });
        const started = await page.evaluate(() => (window as any).cmuxAcpmuxDebug.newChat("claude"));
        expect(started, "the mock starts a new chat").toHaveProperty("sessionId");
        await page.locator(COMPOSER_EDITOR).waitFor({ timeout: 30_000 });
        await page.evaluate(twoFrames);
        await page.evaluate(() => (window as any).cmuxAcpmuxDebug.renders());
        const picked = await page.evaluate((cwd) => (window as any).cmuxAcpmuxDebug.pickFolder(cwd), FOLDER);
        expect(picked).toEqual({ picked: FOLDER });
        await page.locator(TRUST).first().waitFor({ timeout: 30_000 });
        const asked = await page.locator(ASK).first().innerText();
        await page.evaluate(twoFrames);
        const askRenders = (await page.evaluate(() => (window as any).cmuxAcpmuxDebug.renders())) as Record<
          string,
          number
        >;
        await page.locator(TRUST).first().click();
        await page.locator(TRUST).waitFor({ state: "detached", timeout: 30_000 });
        await page.evaluate(twoFrames);
        const left = await page.locator(ASK).count();
        const composer = await page.locator(COMPOSER_EDITOR).count();
        const trustRenders = (await page.evaluate(() => (window as any).cmuxAcpmuxDebug.renders())) as Record<
          string,
          number
        >;
        await page.close();
        console.log(
          `APP-TRUST-HOOK-RENDERS ${JSON.stringify({
            engine: name,
            pane_ask: askRenders.pane ?? 0,
            pane_trust: trustRenders.pane ?? 0,
            askRenders,
            trustRenders,
          })}`,
        );
        expect(asked, "the question names the picked folder").toContain("untrusted-app");
        expect(left, "no trust question after Trust").toBe(0);
        expect(composer, "the composer stays").toBe(1);
        expect(askRenders.pane ?? 0, "pane renders until the question shows").toBeLessThanOrEqual(PANE_ON_BASE.ask);
        expect(trustRenders.pane ?? 0, "pane renders from Trust until it is gone").toBeLessThanOrEqual(
          PANE_ON_BASE.trust,
        );
      });
    });
  }
});
