// Exercise the actual production documents and module graph, with an isolated origin for each
// page, the app's CSP, and its shared-assets mapping. No Vite source fallback can hide a missing
// packaged file. Compare this receipt on the baseline and candidate builds.
// bun scripts/pages/check-bundle.mjs PAGES_DIR RECEIPT_DIR [scheme|daemon] [BASELINE_PAGES_DIR]
import { mkdir, readdir, readFile, stat, writeFile } from "node:fs/promises";
import path from "node:path";
import { chromium } from "playwright";
import { useSystemChrome as configureSystemChrome } from "../../test/support/systemChrome.ts";
import { siteSettings, siteData, certificateChain } from "../../src/browser-chrome/page-info/windowFixtures.ts";

const [input, output, mode = "scheme", baseline] = process.argv.slice(2);
if (!["scheme", "daemon"].includes(mode)) throw new Error("mode must be scheme or daemon");
if (!input || !output)
  throw new Error("usage: check-bundle.mjs PAGES_DIR RECEIPT_DIR [scheme|daemon] [BASELINE_PAGES_DIR]");
if (process.platform === "darwin") throw new Error("Run production-page browser checks on Linux");
const root = path.resolve(input);
await mkdir(output, { recursive: true });
const pages = [];
for (const name of await readdir(root)) {
  if (await stat(path.join(root, name, "index.html")).catch(() => null)) pages.push(name);
}
if (!pages.length) throw new Error("No built page documents found");
// This is the production set emitted by build-pages-web.sh. Refusing a partial directory keeps
// a validation run from looking green while silently skipping a newly shipped page.
const expectedPages = new Set([
  "apps",
  "artifacts",
  "bookmarks",
  "certificate",
  "changelog",
  "chief-inspector",
  "chief-usage",
  "chief-views",
  "cloud",
  "cloud-progress",
  "coderouter",
  "cookie-import",
  "debug-settings",
  "feed",
  "files",
  "github",
  "group-editor",
  "history",
  "home-channels",
  "home-messages",
  "icon-picker",
  "import-history",
  "keybindings",
  "machines",
  "mobile-pairing",
  "onboarding",
  "passwords",
  "server-cards",
  "settings",
  "setup-card",
  "sidebar-chats",
  "site-data",
  "site-settings",
  "stash",
  "stats",
  "task-manager",
  "tasks",
]);
const missingPages = [...expectedPages].filter((name) => !pages.includes(name));
if (missingPages.length) throw new Error(`Production page validation is missing: ${missingPages.join(", ")}`);
pages.sort();
configureSystemChrome(chromium);
const browser = await chromium.launch({ headless: true, timeout: 30_000 });
const receipts = [];
const hostStates = {
  "site-settings": siteSettings,
  "site-data": siteData,
  certificate: certificateChain,
  "cookie-import": {
    title: "Import Cookies",
    importTitle: "Import…",
    notNowTitle: "Not Now",
    neverTitle: "Don't Show Again",
  },
};
try {
  for (const name of pages) {
    const context = await browser.newContext({ viewport: { width: 1200, height: 800 }, locale: "en-US" });
    const errors = [];
    const missing = [];
    const requests = [];
    // A packaging-only change must preserve each document's CSS bytes and cascade order.
    if (baseline) {
      const styles = (document) => document.match(/<style>([\s\S]*?)<\/style>/)?.[1];
      const before = await readFile(path.join(baseline, name, "index.html"), "utf8");
      const after = await readFile(path.join(root, name, "index.html"), "utf8");
      if (styles(before) !== styles(after)) errors.push("Stylesheet differs from baseline");
    }
    const page = await context.newPage();
    if (hostStates[name])
      await page.addInitScript(
        ({ name, state }) => {
          window.webkit = {
            messageHandlers: {
              cmuxPage: {
                async postMessage(message) {
                  if (message.t === "sub") {
                    if (message.stream === `cmux.${name}.state`)
                      queueMicrotask(() => window.__cmuxPageReceive({ t: "ev", sub: message.id, seq: 1, data: state }));
                    return { t: "ok", id: message.id, value: { sub: message.id } };
                  }
                  return { t: "ok", id: message.id, value: {} };
                },
              },
            },
          };
        },
        { name, state: hostStates[name] },
      );
    page.on("pageerror", (error) => errors.push(String(error)));
    await context.route("**/*", async (route) => {
      const url = new URL(route.request().url());
      if (url.hostname !== `${name}.pages.test`) return route.abort();
      const resource = decodeURIComponent(url.pathname);
      const base = mode === "daemon" || resource.startsWith("/__shared/") ? root : path.join(root, name);
      const local = mode === "daemon" ? resource.replace(/^\/pages/, "") : resource;
      const file = path.resolve(base, `.${local.endsWith("/") ? `${local}index.html` : local}`);
      if (!file.startsWith(`${base}/`)) return route.fulfill({ status: 403, body: "Forbidden" });
      requests.push(resource);
      const body = await readFile(file).catch(() => null);
      if (!body) {
        missing.push(resource);
        return route.fulfill({ status: 404, body: "Not found" });
      }
      const type =
        { ".html": "text/html", ".js": "text/javascript", ".css": "text/css" }[path.extname(file)] ??
        "application/octet-stream";
      return route.fulfill({
        body,
        contentType: type,
        headers: {
          "Content-Security-Policy":
            "default-src 'none'; script-src 'self' 'unsafe-inline'; style-src 'self' 'unsafe-inline'; img-src 'self' data:; font-src 'self' data:; worker-src 'self'",
          "X-Content-Type-Options": "nosniff",
        },
      });
    });
    let rendered = false;
    try {
      const route = name === "server-cards" ? "#/pair-invite" : "";
      await page.goto(`http://${name}.pages.test${mode === "daemon" ? `/pages/${name}/` : "/"}?mock${route}`, {
        waitUntil: "load",
        timeout: 30_000,
      });
      await page.waitForFunction(() => document.querySelector("#root")?.childElementCount > 0, null, {
        timeout: 10_000,
      });
      rendered = true;
    } catch (error) {
      errors.push(String(error).split("\n")[0]);
    }
    const text = await page
      .locator("#root")
      .innerText()
      .catch(() => "");
    const capture = `${name}.png`;
    const capturePath = path.join(output, capture);
    await page.screenshot({ path: capturePath });
    const captureSize = (await stat(capturePath)).size;
    if (!captureSize) errors.push("production capture is empty");
    const receipt = { page: name, rendered, text: text.slice(0, 300), capture, captureSize, errors, missing, requests };
    receipts.push(receipt);
    console.log(JSON.stringify(receipt));
    await context.close();
  }
} finally {
  await browser.close();
  await writeFile(path.join(output, "results.json"), JSON.stringify(receipts, null, 2));
  await writeFile(
    path.join(output, "page-captures.json"),
    JSON.stringify(
      { pages: receipts.map(({ page, capture, captureSize, rendered }) => ({ page, capture, captureSize, rendered })) },
      null,
      2,
    ),
  );
}
if (
  receipts.length !== expectedPages.size ||
  receipts.some((item) => !item.rendered || item.missing.length || item.errors.length)
)
  process.exitCode = 1;
