// The first styled frame the WebKit against Chromium bench reads (`debug.agent_pane readiness`'s
// `first_styled_frame_ms`): PageStyledFrameProbe's document-start script keeps the time of the
// first animation frame whose document has the shared theme applied, so a page that never gets
// its theme (#24037: Chromium's document-start apply threw on a missing root) never reports one.
// The script is read from the Swift source and run as the hosts run it: WebKit's document-start
// user script, wrapped as a Chromium new-document script, in real engines.
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import fs from "node:fs";
import path from "node:path";
import { chromium, webkit, type BrowserType, type Page } from "playwright";
import { readWebThemeBootstrap } from "../dev-server/galleryHost";
import { parseGhosttyTheme } from "../src/gallery/theme/ghostty";
import { themeTokens, webThemePayload } from "../src/gallery/theme/web";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("page-styled-frame-probe.test.ts", async () => {
  setDefaultTimeout(120_000);
  const swift = fs.readFileSync(
    path.resolve(import.meta.dir, "../../Packages/macOS/CmuxNext/Sources/CmuxNextPages/PageStyledFrameProbe.swift"),
    "utf8",
  );
  const literal = /static let script = """\n([\s\S]*?)\n[ \t]*"""/.exec(swift)?.[1];
  if (!literal || literal.includes("\\")) throw new Error("PageStyledFrameProbe.script: no escape-free literal");
  const probe = literal;
  /** PageChromiumDocumentScripts.chromiumSource for a main-frame document-start script. */
  const newDocument = (source: string) => `(() => {\nif (window !== window.top) return;\n${source}\n})();`;
  const theme = parseGhosttyTheme("Catppuccin Mocha", "background = #1e1e2e\nforeground = #cdd6f4\n")!;
  const applyScript = `window.cmuxTheme.apply(${JSON.stringify(webThemePayload(themeTokens(theme)))});`;
  const html =
    "<!doctype html><html><head><style>html{color:var(--cmux-text)}</style></head>" +
    "<body><main>chat</main></body></html>";

  let server: ReturnType<typeof Bun.serve> | undefined;
  beforeAll(() => {
    server = Bun.serve({ port: 0, fetch: () => new Response(html, { headers: { "Content-Type": "text/html" } }) });
  });
  afterAll(() => server?.stop());

  const frames = (page: Page, count: number) =>
    page.evaluate(async (count) => {
      for (let frame = 0; frame < count; frame += 1) await new Promise(requestAnimationFrame);
    }, count);
  const styledFrame = (page: Page) =>
    page.evaluate(() => (window as unknown as { __cmuxStyledFrame?: number | null }).__cmuxStyledFrame);

  for (const [name, engine] of [
    ["chromium", chromium],
    ["webkit", webkit],
  ] as [string, BrowserType][]) {
    describe(`${name}: the styled-frame probe`, () => {
      test("waits for the theme, then keeps the frame it first drew with it", async () => {
        const browser = await engine.launch({ headless: true });
        try {
          const page = await browser.newPage();
          await page.addInitScript({ content: newDocument(readWebThemeBootstrap()) });
          await page.addInitScript({ content: newDocument(probe) });
          await page.goto(`http://127.0.0.1:${server!.port}/`);
          await frames(page, 6);
          expect(await styledFrame(page)).toBeNull();
          const appliedAt = await page.evaluate(() => performance.now());
          await page.evaluate(applyScript);
          await frames(page, 3);
          const styled = await styledFrame(page);
          expect(typeof styled).toBe("number");
          // The first frame after the theme: no earlier than one frame before it was applied.
          expect(styled!).toBeGreaterThan(appliedAt - 20);
          expect(styled!).toBeLessThanOrEqual(await page.evaluate(() => performance.now()));
        } finally {
          await browser.close();
        }
      });

      test("a theme that left the text transparent (#24037) is not styled", async () => {
        const browser = await engine.launch({ headless: true });
        try {
          const page = await browser.newPage();
          await page.addInitScript({ content: newDocument(readWebThemeBootstrap()) });
          await page.addInitScript({ content: newDocument(probe) });
          await page.goto(`http://127.0.0.1:${server!.port}/`);
          // What the broken apply left: the color registered at its transparent initial value.
          await page.evaluate(() => {
            CSS.registerProperty({
              name: "--cmux-text",
              syntax: "<color>",
              inherits: true,
              initialValue: "transparent",
            });
            (window as unknown as { cmuxTheme: { current: unknown } }).cmuxTheme.current = {};
          });
          await frames(page, 6);
          expect(await styledFrame(page)).toBeNull();
        } finally {
          await browser.close();
        }
      });

      test("a document-start theme styles the first frames", async () => {
        const browser = await engine.launch({ headless: true });
        try {
          const page = await browser.newPage();
          await page.addInitScript({ content: newDocument(readWebThemeBootstrap()) });
          await page.addInitScript({ content: newDocument(applyScript) });
          await page.addInitScript({ content: newDocument(probe) });
          await page.goto(`http://127.0.0.1:${server!.port}/`);
          await frames(page, 3);
          const styled = await styledFrame(page);
          expect(typeof styled).toBe("number");
          expect(styled!).toBeLessThan(await page.evaluate(() => performance.now()));
        } finally {
          await browser.close();
        }
      });
    });
  }
});
