// The shipped agent pane (Resources/agent-pane) paints its first frame in the app's language: the
// <head> loads English plus the active locale (locales/<code>.js, same origin, before the module
// runs), so there is no frame of English and no fetch before first paint. The page is served as
// built, with its own meta CSP, and under the app's real response header: the page host's
// PageDescriptor.agent header (test/fixtures/agent-page-csp.txt, which AgentPageProviderTests
// checks against the Swift value). The cmux-agent://pane scheme sends no header, so the meta CSP
// alone governs it. Real engines (Playwright Chromium and WebKit); skipped where they are not
// installed.
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import fs from "node:fs";
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

/** The page host's Content-Security-Policy header for the agent page, exactly as the app sends it. */
const APP_CSP = fs.readFileSync(path.join(import.meta.dir, "fixtures/agent-page-csp.txt"), "utf8");
/** A policy without 'self' in script-src: it blocks the locale files, so the test can tell. */
const NO_SELF_CSP = APP_CSP.replace("script-src 'self' 'unsafe-inline'", "script-src 'unsafe-inline'");

let server: ReturnType<typeof Bun.serve> | undefined;
const requests: string[] = [];
/** The CSP header the server sends; undefined sends none (the cmux-agent://pane scheme). */
let csp: string | undefined;
beforeAll(() => {
  server = Bun.serve({
    port: 0,
    fetch(request) {
      const name = new URL(request.url).pathname.replace(/^\/+/, "") || "index.html";
      requests.push(name);
      const file = Bun.file(path.join(pane, path.normalize(name).replace(/^(\.\.(\/|$))+/, "")));
      return new Response(file, csp ? { headers: { "Content-Security-Policy": csp } } : undefined);
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

/// The first text the pane paints in a German app, and the locale files it asked for.
async function germanFirstPaint(engine: BrowserType): Promise<{ first: string; locales: string[] }> {
  const browser = await engine.launch({ headless: true });
  try {
    const page = await (await browser.newContext({ locale: "de-DE" })).newPage();
    await page.addInitScript(FIRST_TEXT);
    requests.length = 0;
    await page.goto(`http://127.0.0.1:${server!.port}/index.html`);
    await page.waitForFunction(() => (window as { __firstText?: string }).__firstText);
    const first = await page.evaluate(() => (window as { __firstText?: string }).__firstText ?? "");
    return { first, locales: requests.filter((request) => request.startsWith("locales/")).sort() };
  } finally {
    await browser.close();
  }
}

describe("agent pane first paint", () => {
  for (const [name, engine] of engines) {
    for (const [policy, header] of [
      ["its own meta CSP (cmux-agent://pane)", undefined],
      ["the page host's CSP header", APP_CSP],
    ] as const)
      test(`${name}: under ${policy}, a German app paints German from the first frame`, async () => {
        csp = header;
        const { first, locales } = await germanFirstPaint(engine);
        expect(first).toContain("Ordner auswählen");
        expect(first).not.toContain("Choose folder");
        // English and German only, not all 21 locales.
        expect(locales).toEqual(["locales/de.js", "locales/en.js"]);
      });

    test(`${name}: a policy without 'self' blocks the locale files, so the checks above can fail`, async () => {
      csp = NO_SELF_CSP;
      const { first } = await germanFirstPaint(engine);
      expect(first).not.toContain("Ordner auswählen");
    });
  }
});
