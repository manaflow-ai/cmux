// l10n-allow-file: gallery assertions, not shipped UI.
// GitHub's HTML of a body is parsed in an inert DOMParser document: it has no browsing context, so
// nothing in it loads (an image, a source, a stylesheet, a frame, a video poster) before the
// allowlist runs. Then only GitHub's image proxy and inline images draw.
import { afterAll, beforeAll, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser } from "playwright";
import { galleryFrame, warmGalleryFrame } from "../support/galleryFrame";
import { requireBrowserLane } from "../support/requireBrowserLane";

await requireBrowserLane("github-page-html-network.test.ts", async () => {
  setDefaultTimeout(180_000);
  const { createServer } = await import("vite");
  let vite: Awaited<ReturnType<typeof createServer>>;
  let browser: Browser;
  let base: string;
  beforeAll(async () => {
    const root = path.resolve(import.meta.dir, "../..");
    vite = await createServer({
      root,
      configFile: path.join(root, "vite.config.gallery-dev.ts"),
      server: { host: "127.0.0.1", port: 0 },
      logLevel: "error",
    });
    await vite.listen();
    base = `http://127.0.0.1:${(vite.httpServer!.address() as { port: number }).port}`;
    browser = await chromium.launch({ headless: true });
    await warmGalleryFrame(vite, "pages.github", { browser, timeoutMs: 120_000 });
  });
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });

  test("parsing a body's HTML loads nothing, and the drawn bot comments load nothing off the proxy", async () => {
    const page = await browser.newPage({ viewport: { width: 1200, height: 900 } });
    const requested: string[] = [];
    page.on("request", (request) => requested.push(request.url()));
    try {
      await page.goto(`${base}${galleryFrame("pages.github", { variant: "bot-comments", reducedMotion: 1 })}`);
      await page.waitForFunction(() => document.documentElement.dataset.galleryReady === "1");
      await page.locator(".gh-md details").first().waitFor();
      // The same parse githubHTML.tsx runs, on every kind of element that could fetch, at a host
      // that would answer (this server), so a fetch would show as a request.
      await page.evaluate((origin) => {
        const at = (name: string) => `${origin}/__probe/${name}`;
        const html = [
          `<img src="${at("img")}" srcset="${at("srcset")} 2x">`,
          `<picture><source srcset="${at("source")}"><img src="${at("picture-img")}"></picture>`,
          `<link rel="stylesheet" href="${at("link")}"><link rel="preload" as="image" href="${at("preload")}">`,
          `<iframe src="${at("iframe")}"></iframe><video poster="${at("poster")}"></video><audio src="${at("audio")}"></audio>`,
          `<object data="${at("object")}"></object><embed src="${at("embed")}">`,
          `<div style="background:url(${at("style")})"></div><style>p{background:url(${at("sheet")})}</style><p>x</p>`,
          `<script src="${at("script")}"></script>`,
        ].join("");
        new DOMParser().parseFromString(`<body>${html}</body>`, "text/html");
      }, base);
      // The control, after it: the same kind of image in the live page is fetched. Once its request
      // is out, any the parse had started would be too, so only it may show.
      const live = page.waitForRequest((request) => request.url().endsWith("/__probe/live"));
      await page.evaluate((origin) => {
        document.body.insertAdjacentHTML("beforeend", `<img src="${origin}/__probe/live">`);
      }, base);
      await live;
      expect(requested.filter((url) => url.includes("/__probe/"))).toEqual([`${base}/__probe/live`]);
      // The fixture's off-proxy tracking image drew as nothing and was never asked for.
      expect(requested.filter((url) => url.includes("tracker.example"))).toEqual([]);
    } finally {
      await page.close();
    }
  });
});
