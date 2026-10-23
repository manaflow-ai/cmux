// A new chat's unsent draft in the real agent pane (cx-z5vd). The page is the pane's dev entry
// (vite.config.acpmux-pane.mjs) with a stand-in host bridge (window.webkit.messageHandlers) and the
// in-page mock transport, as a chat that has not sent its first prompt has no acpmux session.
//
// - Such a chat hands its typed text to the host (`chat.unsentDraft`), which keeps it with the tab
//   across a relaunch (AgentUnsentDrafts); a relaunch hands it back as the handshake's `draft`.
// - The text it shows from that draft goes back to the host too, so it is kept again.
//
// Real Chromium from Playwright; CI fails the file when it cannot launch (requireBrowserLane).
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser, type Page } from "playwright";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { warmViteServer } from "./support/warmDevServer";

await requireBrowserLane("agent-pane-unsent-draft.test.ts", async () => {
  setDefaultTimeout(120_000);
  try {
    await (await chromium.launch({ headless: true })).close();
  } catch {
    console.warn("agent-pane-unsent-draft: skipping (run `bunx playwright install chromium`)");
    describe.skip("unsent draft", () => test("chromium", () => {}));
    return;
  }
  const { createServer } = await import("vite");
  const webviews = path.resolve(import.meta.dir, "..");

  let vite: Awaited<ReturnType<typeof createServer>> | undefined;
  let browser: Browser | undefined;
  beforeAll(async () => {
    vite = await createServer({
      configFile: path.join(webviews, "vite.config.acpmux-pane.mjs"),
      server: { port: 0, host: "127.0.0.1", strictPort: false },
      logLevel: "error",
    });
    await vite.listen();
    await warmViteServer(vite, "/");
    browser = await chromium.launch({ headless: true });
  });
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });

  /// A new chat whose host hands it `draft` (a relaunch's kept text), recording what the page
  /// hands back with `chat.unsentDraft`.
  async function newChat(draft?: string): Promise<Page> {
    const page = await browser!.newPage({ viewport: { width: 900, height: 640 } });
    await page.addInitScript(
      ({ draft }) => {
        const unsent: string[] = [];
        Object.assign(window, {
          unsentDrafts: unsent,
          webkit: {
            messageHandlers: {
              agentSession: {
                postMessage: async ({ method, params }: { method: string; params: Record<string, unknown> }) => {
                  if (method === "chat.unsentDraft") unsent.push(String(params.text));
                  return { ok: true, value: null };
                },
              },
            },
          },
          cmuxAcpmuxActions: {
            ready: async () => ({
              protocolVersion: 1,
              transport: "mock",
              newSession: true,
              ...(draft ? { draft } : {}),
            }),
          },
        });
      },
      { draft },
    );
    const { port } = vite!.httpServer!.address() as { port: number };
    await page.goto(`http://127.0.0.1:${port}/`);
    await page.locator(".acpmux-composer-prompt").waitFor();
    return page;
  }

  /// The last text the page handed the host, once it is `expected` (else what it is after 5 s).
  async function lastUnsent(page: Page, expected: string): Promise<string | undefined> {
    const read = () => page.evaluate(() => (window as unknown as { unsentDrafts: string[] }).unsentDrafts.at(-1));
    await page
      .waitForFunction(
        (expected) => (window as unknown as { unsentDrafts: string[] }).unsentDrafts.at(-1) === expected,
        expected,
        { timeout: 5_000 },
      )
      .catch(() => {});
    return read();
  }

  describe("unsent draft", () => {
    test("a new chat hands its typed text to the host", async () => {
      const page = await newChat();
      await page.locator(".acpmux-composer-prompt").click();
      await page.keyboard.type("compare the two retry policies");
      expect(await lastUnsent(page, "compare the two retry policies")).toBe("compare the two retry policies");
      await page.close();
    });

    test("a relaunched new chat shows its kept draft and keeps what is typed after it", async () => {
      const page = await newChat("compare the two");
      const prompt = page.locator(".acpmux-composer-prompt .ProseMirror");
      await page.getByText("compare the two").waitFor();
      await page.locator(".acpmux-composer-prompt").click();
      await page.keyboard.press("End");
      await page.keyboard.type(" retry policies");
      expect((await prompt.innerText()).trim()).toBe("compare the two retry policies");
      expect(await lastUnsent(page, "compare the two retry policies")).toBe("compare the two retry policies");
      await page.close();
    });
  });
});
