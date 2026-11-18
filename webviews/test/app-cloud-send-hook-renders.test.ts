// cmux-web-test-timeout: 300
// l10n-allow-file: test fixture prompts, not shipped UI.
// The Cloud send moved out of the pane (App.tsx) into its own hook (acpmux/useCloudSend.ts), which the React
// Compiler compiles. The move changes nothing the person sees and draws the pane no more often: a new chat's
// prompt sent to Cloud shows the start under it, a start the host refuses fails on its card with Retry, and
// Retry sends the same prompt again under the same start key (cloudRun.ts `cloudStartKeys`), the card
// starting again. The pane's renders over that send and retry stay at or under what the pane drew before
// the move (PANE_RENDERS, measured on the base).
//
// The page is the pane's dev entry with the in-page mock daemon; a stand-in for the app's bridge answers
// the host's side (the handshake offers Cloud, `cloud.startChat` refuses the first start and holds the
// second). Real Chromium and WebKit; CI fails the file when one cannot launch.
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, webkit, type Browser, type BrowserType, type Page } from "playwright";
import { probeEngineOrSkip, requireBrowserLane } from "./support/requireBrowserLane";
import { warmViteServer } from "./support/warmDevServer";
import { COMPOSER_EDITOR } from "../src/agent-session/acpmux/composerSelectors";

const PROMPT = "Run the sidebar tests and fix what fails";
const CARD = ".acpmux-cloud-start";
const RETRY = ".acpmux-cloud-start__retry";
/// The pane's renders over the send, the refusal and the retry, per engine, as the base drew them (b4933ba8547: 3 and 3).
const PANE_RENDERS: Record<string, number> = { chromium: 3, webkit: 3 };

type StartCall = { key?: unknown; task?: unknown };

await requireBrowserLane("app-cloud-send-hook-renders.test.ts", async () => {
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

  /// A new chat in a folder where the host offers Cloud, Cloud picked, the prompt typed.
  async function openPane(browser: Browser): Promise<Page> {
    const page = await browser.newPage({ viewport: { width: 900, height: 760 } });
    await page.addInitScript(() => {
      const starts: { key?: unknown; task?: unknown }[] = [];
      const ok = (value: unknown) => Promise.resolve({ ok: true, value });
      Object.assign(window, {
        __cloudStarts: starts,
        webkit: {
          messageHandlers: {
            agentSession: {
              standIn: true,
              postMessage: (message: { method?: string; params?: Record<string, unknown> }) => {
                switch (message.method) {
                  case "ready":
                    return ok({
                      protocolVersion: 1,
                      transport: "mock",
                      machineName: "This Mac",
                      newSession: true,
                      sandboxState: true,
                      cwd: "~/code/cmux",
                    });
                  case "sandbox.state":
                    return ok({});
                  case "transport.gesture":
                    return ok({ ticket: "renders-test" });
                  case "cloud.startChat": {
                    starts.push({ key: message.params?.key, task: message.params?.task });
                    // The first start fails as a machine that stopped answering does; the retry stays out.
                    if (starts.length === 1)
                      return Promise.resolve({
                        ok: false,
                        error: {
                          code: "cloud_start_failed",
                          userMessage: "The machine stopped answering.",
                          retryable: true,
                        },
                      });
                    return new Promise(() => undefined);
                  }
                  default:
                    return ok(null);
                }
              },
            },
          },
        },
      });
    });
    await page.goto(`${base}/?mock`);
    await page.waitForFunction(() => "cmuxAcpmuxDebug" in window, null, { timeout: 60_000 });
    await page.locator(COMPOSER_EDITOR).waitFor({ timeout: 60_000 });
    await page.waitForFunction(() => (window as any).cmuxAcpmuxDebug.runMode("cloud").runMode === "cloud", null, {
      timeout: 30_000,
    });
    await page.locator(COMPOSER_EDITOR).click();
    await page.keyboard.type(PROMPT);
    await page.waitForFunction(([editor, text]) => document.querySelector(editor)?.textContent?.includes(text), [
      COMPOSER_EDITOR,
      PROMPT,
    ] as const);
    await page.evaluate(twoFrames);
    return page;
  }

  const engines: [string, BrowserType][] = [
    ["chromium", chromium],
    ["webkit", webkit],
  ];
  for (const [name, engine] of engines) {
    if (!(await probeEngineOrSkip(`app-cloud-send-hook-renders (${name})`, name, engine))) continue;
    describe(name, () => {
      let browser: Browser | undefined;
      beforeAll(async () => {
        browser = await engine.launch({ headless: true });
      });
      afterAll(async () => {
        await browser?.close();
      });

      test("a Cloud send, its refusal and Retry show on the start's card and draw the pane no more than before", async () => {
        const page = await openPane(browser!);
        await page.evaluate(() => (window as any).cmuxAcpmuxDebug.renders());
        await page.keyboard.press("Enter");
        await page.locator(`${CARD}[data-state='failed']`).waitFor({ timeout: 30_000 });
        const failedText = await page.locator(CARD).innerText();
        const promptAfterFailure = await page.locator(COMPOSER_EDITOR).innerText();
        await page.locator(RETRY).click();
        await page.locator(`${CARD}[data-state='starting']`).waitFor({ timeout: 30_000 });
        await page.waitForFunction(() => (window as any).__cloudStarts.length === 2);
        await page.evaluate(twoFrames);
        const renders = (await page.evaluate(() => (window as any).cmuxAcpmuxDebug.renders())) as Record<
          string,
          number
        >;
        const starts = (await page.evaluate(() => (window as any).__cloudStarts)) as StartCall[];
        const startingText = await page.locator(CARD).innerText();
        await page.close();
        console.log(
          `APP-CLOUD-SEND-RENDERS ${JSON.stringify({
            engine: name,
            pane: renders.pane ?? 0,
            composer: renders.composer ?? 0,
            starts: starts.length,
          })}`,
        );
        // The refused start's card says so, and its prompt is back in the composer for Retry.
        expect(failedText, "the failed card").toContain("The machine stopped answering.");
        expect(promptAfterFailure, "the prompt back in the composer").toContain(PROMPT);
        // Retry sends the prompt again under the first start's key, so the host reaches the machine it made.
        expect(starts.length, "starts sent").toBe(2);
        expect(starts[1]!.key, "the retry's start key").toBe(starts[0]!.key);
        expect(startingText, "the starting card shows the prompt").toContain(PROMPT);
        expect(renders.pane ?? 0, "pane renders over the send and the retry").toBeLessThanOrEqual(PANE_RENDERS[name]!);
      });
    });
  }
});
