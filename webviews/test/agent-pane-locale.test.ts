// The shipped agent pane (Resources/agent-pane) paints its first frame in the app's language: the
// <head> loads English plus the active locale (locales/<code>.js, same origin, before the module
// runs), so there is no frame of English and no fetch before first paint. Real engines
// (Playwright Chromium and WebKit); skipped where they are not installed.
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, webkit, type BrowserType } from "playwright";

setDefaultTimeout(120_000);
const pane = path.resolve(
  import.meta.dir,
  "../../Packages/macOS/CmuxNext/Sources/CmuxNextAgentPane/Resources/agent-pane",
);
const engines: [string, BrowserType][] = [];
for (const engine of [
  ["chromium", chromium],
  ["webkit", webkit],
] as [string, BrowserType][]) {
  try {
    await (await engine[1].launch({ headless: true })).close();
    engines.push(engine);
  } catch {
    console.warn(`agent-pane-locale: skipping ${engine[0]} (run \`bunx playwright install ${engine[0]}\`)`);
  }
}

let server: ReturnType<typeof Bun.serve> | undefined;
const requests: string[] = [];
beforeAll(() => {
  server = Bun.serve({
    port: 0,
    fetch(request) {
      const name = new URL(request.url).pathname.replace(/^\/+/, "") || "index.html";
      requests.push(name);
      const file = Bun.file(path.join(pane, path.normalize(name).replace(/^(\.\.(\/|$))+/, "")));
      return new Response(file);
    },
  });
});
afterAll(() => server?.stop());

/// The text of #root the first time it has any, recorded before the page's scripts run.
const FIRST_TEXT = `
  new MutationObserver((_, observer) => {
    const root = document.getElementById("root");
    const text = root && root.innerText.trim();
    if (text) { window.__firstText = text; observer.disconnect(); }
  }).observe(document, { subtree: true, childList: true, characterData: true });
`;

describe("agent pane first paint", () => {
  for (const [name, engine] of engines)
    test(`${name}: a German app paints German from the first frame`, async () => {
      const browser = await engine.launch({ headless: true });
      try {
        const page = await (await browser.newContext({ locale: "de-DE" })).newPage();
        await page.addInitScript(FIRST_TEXT);
        requests.length = 0;
        await page.goto(`http://127.0.0.1:${server!.port}/index.html`);
        await page.waitForFunction(() => (window as { __firstText?: string }).__firstText);
        const first = await page.evaluate(() => (window as { __firstText?: string }).__firstText ?? "");
        expect(first).toContain("Ordner auswählen");
        expect(first).not.toContain("Choose folder");
        // English and German only, not all 21 locales.
        expect(requests.filter((request) => request.startsWith("locales/")).sort()).toEqual([
          "locales/de.js",
          "locales/en.js",
        ]);
      } finally {
        await browser.close();
      }
    });
});
