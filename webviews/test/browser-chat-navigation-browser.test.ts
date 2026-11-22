// l10n-allow-file: navigation fixture labels, not shipped UI.
// Real browser history and clicks exercise the adapter used by the /app/ shell.
import { afterAll, beforeAll, expect, setDefaultTimeout, test } from "bun:test";
import { build } from "esbuild";
import { chromium, type Browser } from "playwright";
import { probeEngineOrSkip, requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("browser-chat-navigation-browser.test.ts", async () => {
  if (!(await probeEngineOrSkip("browser-chat-navigation-browser", "chromium", chromium))) return;
  setDefaultTimeout(60_000);
  let browser: Browser;
  let server: ReturnType<typeof Bun.serve>;
  let origin: string;

  beforeAll(async () => {
    const built = await build({
      stdin: {
        contents: `
          import { installBrowserNavigation } from "./src/agent-session/browser/routes";
          window.selected = [];
          // The shell consumes its launch token before installing navigation.
          history.replaceState(null, "", location.pathname + location.search);
          window.navigationAdapter = installBrowserNavigation(route => {
            window.selected.push(route ?? null);
            document.querySelector("output").textContent = JSON.stringify(route ?? null);
          });
        `,
        resolveDir: new URL("../", import.meta.url).pathname,
        loader: "ts",
      },
      bundle: true,
      format: "iife",
      platform: "browser",
      write: false,
    });
    const bundle = built.outputFiles[0]!.text;
    server = Bun.serve({
      hostname: "127.0.0.1",
      port: 0,
      fetch(request) {
        if (new URL(request.url).pathname === "/routes.js")
          return new Response(bundle, { headers: { "Content-Type": "text/javascript" } });
        return new Response(
          `<!doctype html><body>
          <a id="session" href="cmux-nightly://session/second#turn-turn-2">Session</a>
          <a id="agent" href="https://cmux.com/deeplink/agent?id=aid-0123456789abcdef0123&token=secret">Agent</a>
          <a id="newtab" href="/app/?session=third" target="_blank">New tab</a>
          <output></output><script src="/routes.js"></script></body>`,
          { headers: { "Content-Type": "text/html" } },
        );
      },
    });
    origin = server.url.origin;
    browser = await chromium.launch({ headless: true });
  });
  afterAll(async () => {
    await browser?.close();
    await server?.stop(true);
  });

  test("click, Back, Forward and reload restore the same chat and row without a token", async () => {
    const page = await browser.newPage();
    try {
      await page.goto(`${origin}/app/?session=first#token=launch-secret`);
      await page.waitForFunction(() => document.querySelector("output")?.textContent === '{"session":"first"}');
      await page.locator("#session").click();
      expect(new URL(page.url()).searchParams.get("session")).toBe("second");
      expect(new URL(page.url()).searchParams.get("turn")).toBe("turn-2");
      await page.locator("#agent").click();
      expect(decodeURIComponent(page.url())).not.toContain("secret");
      await page.goBack();
      await page.waitForFunction(() => document.querySelector("output")?.textContent?.includes('"turn":"turn-2"'));
      await page.goBack();
      await page.waitForFunction(() => document.querySelector("output")?.textContent === '{"session":"first"}');
      expect(page.url()).not.toContain("token");
      await page.goForward();
      await page.reload();
      await page.waitForFunction(() => document.querySelector("output")?.textContent?.includes('"turn":"turn-2"'));
      expect(page.url()).toBe(`${origin}/app/?session=second&turn=turn-2`);
    } finally {
      await page.close();
    }
  });

  test("modified clicks and new-tab links keep native browser behavior, disposal removes handlers", async () => {
    const page = await browser.newPage();
    try {
      await page.goto(`${origin}/app/?session=first`);
      await page.waitForFunction(() => !!(window as any).navigationAdapter);
      const result = await page.evaluate(() => {
        const dispatch = (id: string, options: MouseEventInit) => {
          const event = new MouseEvent("click", { bubbles: true, cancelable: true, ...options });
          // Suppress browser default after the adapter has had its capture phase.
          document.getElementById(id)!.addEventListener("click", (e) => e.preventDefault(), { once: true });
          document.getElementById(id)!.dispatchEvent(event);
        };
        dispatch("session", { ctrlKey: true });
        dispatch("newtab", {});
        const beforeDispose = (window as any).selected.length;
        (window as any).navigationAdapter.dispose();
        dispatch("session", {});
        history.pushState(null, "", "/app/?session=other");
        dispatchEvent(new PopStateEvent("popstate"));
        return { beforeDispose, afterDispose: (window as any).selected.length };
      });
      expect(result).toEqual({ beforeDispose: 1, afterDispose: 1 });
    } finally {
      await page.close();
    }
  });
});
