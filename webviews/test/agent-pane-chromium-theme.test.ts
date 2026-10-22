// The shipped agent pane gets its theme at document start in Chromium too (Leo 2026-10-21: "MY
// LITERAL ENTIRE NIGHTLY THE AGENT PANE HAS NO STYLING NO BACKGROUND"). The agent chat moved to
// the page host in Chromium (agent.chromium), which runs the page's WebKit user scripts as
// new-document scripts (PageChromiumDocumentScripts): those run before the parser makes <html>.
// WebTheme's document-start apply then registered every `--cmux-*` color (initial value
// transparent) and threw in setTransition on a null root, so the chat's text and background stayed
// transparent. The page here is the built resource (CI builds the web bundles before this suite;
// locally run scripts/cmux-next/build-agent-pane-web.sh first), served under the page host's real
// CSP header, with WebTheme.bootstrapScript and its apply wrapped exactly as the Chromium page host
// wraps them. Its first state must already be the themed one: the same as after the host applies
// the theme again once the document finished. Real engines (Playwright Chromium and WebKit, whose
// init scripts also run before <html>).
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import fs from "node:fs";
import path from "node:path";
import { chromium, webkit, type BrowserType } from "playwright";
import { readWebThemeBootstrap } from "../dev-server/galleryHost";
import { parseGhosttyTheme } from "../src/gallery/theme/ghostty";
import { themeTokens, webThemePayload } from "../src/gallery/theme/web";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("agent-pane-chromium-theme.test.ts", async () => {
  setDefaultTimeout(120_000);
  const pane = path.resolve(
    import.meta.dir,
    "../../Packages/macOS/CmuxNext/Sources/CmuxNextAgentPane/Resources/agent-pane",
  );
  if (!fs.existsSync(path.join(pane, "index.html")))
    throw new Error(
      `agent-pane-chromium-theme: ${pane}/index.html is not built (scripts/cmux-next/build-agent-pane-web.sh)`,
    );

  /** The page host's Content-Security-Policy header for the agent page, as the app sends it. */
  const APP_CSP = fs.readFileSync(path.join(import.meta.dir, "fixtures/agent-page-csp.txt"), "utf8").trim();
  const theme = parseGhosttyTheme("Catppuccin Mocha", "background = #1e1e2e\nforeground = #cdd6f4\n")!;
  const payload = { ...webThemePayload(themeTokens(theme)), transition: { duration: "200ms", easing: "ease-out" } };
  /** PageChromiumDocumentScripts.chromiumSource for a main-frame document-start script. */
  const newDocument = (source: string) => `(() => {\nif (window !== window.top) return;\n${source}\n})();`;
  /** WebTheme.applyScript: what PageWebView.installDocumentStartTheme adds after the bootstrap. */
  const applyScript = `window.cmuxTheme && window.cmuxTheme.apply(${JSON.stringify(payload)});`;

  let server: ReturnType<typeof Bun.serve> | undefined;
  beforeAll(() => {
    server = Bun.serve({
      port: 0,
      fetch(request) {
        const name = new URL(request.url).pathname.replace(/^\/+/, "") || "index.html";
        const file = Bun.file(path.join(pane, path.normalize(name).replace(/^(\.\.(\/|$))+/, "")));
        return new Response(file, { headers: { "Content-Security-Policy": APP_CSP } });
      },
    });
  });
  afterAll(() => server?.stop());

  type Look = {
    surface: string;
    htmlBackground: string;
    rootColor: string;
    rootFont: string;
    composerColor: string | null;
    composerBackground: string | null;
    themeStyle: boolean;
  };
  const look = (): Look => {
    const root = getComputedStyle(document.documentElement);
    const composer = document.querySelector(".acpmux-composer");
    return {
      surface: root.getPropertyValue("--cmux-surface-background").trim(),
      htmlBackground: root.backgroundColor,
      rootColor: root.color,
      rootFont: root.fontFamily,
      composerColor: composer ? getComputedStyle(composer).color : null,
      composerBackground: composer ? getComputedStyle(composer).backgroundColor : null,
      themeStyle: !!document.getElementById("cmux-theme"),
    };
  };

  for (const [name, engine] of [
    ["chromium", chromium],
    ["webkit", webkit],
  ] as [string, BrowserType][]) {
    describe(`${name}: the built agent pane under the app's document-start scripts`, () => {
      test("is themed from the start: background, text and the composer, with no page error", async () => {
        const browser = await engine.launch({ headless: true });
        try {
          const page = await browser.newPage({ viewport: { width: 900, height: 700 } });
          const errors: string[] = [];
          page.on("pageerror", (error) => errors.push(error.message));
          await page.addInitScript({ content: newDocument(readWebThemeBootstrap()) });
          await page.addInitScript({ content: newDocument(applyScript) });
          await page.goto(`http://127.0.0.1:${server!.port}/index.html`);
          await page.waitForSelector(".acpmux-composer");
          await page.evaluate(
            () => new Promise((resolve) => requestAnimationFrame(() => requestAnimationFrame(resolve))),
          );
          const first = await page.evaluate(look);
          // What PageWebView.documentFinished applies again: the theme as the host would leave it.
          await page.evaluate(applyScript);
          await page.evaluate(
            () => new Promise((resolve) => requestAnimationFrame(() => requestAnimationFrame(resolve))),
          );
          const settled = await page.evaluate(look);

          expect(errors).toEqual([]);
          // The pane's own stylesheet applied: its font, not the engine's default serif.
          expect(first.rootFont).toContain("-apple-system");
          // The theme applied: the page background rule, the surface color, readable text.
          expect(first.themeStyle).toBe(true);
          expect(first.surface).not.toBe("");
          expect(first.htmlBackground).toBe(settled.htmlBackground);
          expect(first.htmlBackground).not.toBe("rgba(0, 0, 0, 0)");
          expect(first.rootColor).not.toBe("rgba(0, 0, 0, 0)");
          expect(first.composerColor).not.toBe("rgba(0, 0, 0, 0)");
          expect(first).toEqual(settled);
        } finally {
          await browser.close();
        }
      });
    });
  }
});
