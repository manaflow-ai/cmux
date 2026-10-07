// The shipped agent pane (Resources/agent-pane) paints its first frame in the app's language: the
// <head> loads English plus the active locale (locales/<code>.js, same origin, before the module
// runs), so there is no frame of English and no fetch before first paint. The page is served as
// built, with its own meta CSP, and under the app's real response header: the page host's
// PageDescriptor.agent header (test/fixtures/agent-page-csp.txt, which AgentPageProviderTests
// checks against the Swift value). The cmux-agent://pane scheme sends no header with the page
// document, so the meta CSP alone governs it. Both policies allow only same-origin script files (script-src 'self', no
// 'unsafe-inline'): the page runs with no CSP violation, and markup injected into it (an agent's
// output rendered as HTML) cannot run script. Real engines (Playwright Chromium and WebKit);
// skipped where they are not installed.
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import fs from "node:fs";
import path from "node:path";
import { chromium, webkit, type BrowserType } from "playwright";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("agent-pane-locale.test.ts", async () => {
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
  /** A policy without 'self' in script-src: it blocks the pane's script files, so the test can tell. */
  const NO_SELF_CSP = APP_CSP.replace("script-src 'self'", "script-src 'unsafe-inline'");

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

  /// The text of #root the first time it has any, and every CSP violation, recorded before the
  /// page's scripts run.
  const FIRST_TEXT = `
  window.__violations = [];
  document.addEventListener("securitypolicyviolation", (event) => {
    window.__violations.push(event.violatedDirective + " " + (event.blockedURI || "inline"));
  });
  new MutationObserver((_, observer) => {
    const root = document.getElementById("root");
    const text = root && root.innerText.trim();
    if (text) { window.__firstText = text; observer.disconnect(); }
  }).observe(document, { subtree: true, childList: true, characterData: true });
`;

  type Paint = { first: string; locales: string[]; violations: string[]; injectedRan: boolean };

  /// The first text the pane paints in a German app (empty when it paints nothing), the locale files
  /// it asked for, its CSP violations, and whether an inline handler in injected markup ran.
  async function germanFirstPaint(engine: BrowserType): Promise<Paint> {
    const browser = await engine.launch({ headless: true });
    try {
      const page = await (await browser.newContext({ locale: "de-DE" })).newPage();
      await page.addInitScript(FIRST_TEXT);
      requests.length = 0;
      await page.goto(`http://127.0.0.1:${server!.port}/index.html`);
      await page
        .waitForFunction(() => (window as { __firstText?: string }).__firstText, null, { timeout: 15_000 })
        .catch(() => {});
      const first = await page.evaluate(() => (window as { __firstText?: string }).__firstText ?? "");
      const violations = await page.evaluate(() => (window as { __violations?: string[] }).__violations ?? []);
      // Markup an agent could get rendered as HTML: its handler must not run.
      await page.evaluate(() => {
        const holder = document.createElement("div");
        holder.innerHTML = `<img src="data:," onerror="window.__injected = true">`;
        document.body.append(holder);
      });
      await page.waitForTimeout(200);
      const injectedRan = await page.evaluate(() => (window as { __injected?: boolean }).__injected === true);
      return {
        first,
        locales: requests.filter((request) => request.startsWith("locales/")).sort(),
        violations,
        injectedRan,
      };
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
        test(`${name}: under ${policy}, a German app paints German from the first frame, script files only`, async () => {
          csp = header;
          const { first, locales, violations, injectedRan } = await germanFirstPaint(engine);
          expect(first).toContain("Ordner auswählen");
          expect(first).not.toContain("Choose folder");
          // English and German only, not all 21 locales, plus the loader that picks German.
          expect(locales).toEqual(["locales/de.js", "locales/en.js", "locales/loader.js"]);
          expect(violations).toEqual([]);
          expect(injectedRan).toBe(false);
        });

      test(`${name}: a policy without 'self' blocks the pane's scripts, so the checks above can fail`, async () => {
        csp = NO_SELF_CSP;
        const { first } = await germanFirstPaint(engine);
        expect(first).not.toContain("Ordner auswählen");
      });
    }
  });
});
