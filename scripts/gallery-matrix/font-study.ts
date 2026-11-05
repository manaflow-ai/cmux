// The font study's captures (webviews/src/gallery/fontStudy): every pairing on the same mock-app screen
// (the sidebar with groups and long names, a long reply with code, a table, CJK and emoji, the
// composer), dark and light, at the app's size. Writes, per pairing and scheme, the whole window, the
// sidebar and the pane, plus `index.json` and a contact sheet (`index.html`). Browsers run only off a
// laptop (README.md): `CMUX_GALLERY_IN_VM=1`, as `cmux-ci test` sets up.
//
//   CMUX_GALLERY_IN_VM=1 bun font-study.ts --gallery-dir ../../webviews/dist/gallery --output-dir out [--only a,b]
import { mkdirSync, writeFileSync } from "node:fs";
import { join, normalize } from "node:path";
import { parseArgs } from "node:util";
import { chromium } from "playwright";

const { values } = parseArgs({
  options: {
    "gallery-dir": { type: "string" },
    "output-dir": { type: "string", default: "font-study-output" },
    only: { type: "string" },
    window: { type: "string", default: "pro14" },
    pairings: { type: "string" },
  },
});
if (process.env.CMUX_GALLERY_IN_VM !== "1") throw new Error("browsers render only in a VM or on CI (CMUX_GALLERY_IN_VM=1)");
const galleryDir = values["gallery-dir"];
if (!galleryDir) throw new Error("--gallery-dir is required");
const outputDir = values["output-dir"]!;
mkdirSync(outputDir, { recursive: true });

// The pairings to capture, by id (webviews/src/gallery/fontStudy/candidates.ts PAIRINGS).
const ids = (values.pairings ?? "").split(",").filter(Boolean);
if (ids.length === 0) throw new Error("--pairings id,id,... is required (webviews/src/gallery/fontStudy/candidates.ts)");
const only = values.only?.split(",").filter(Boolean);
const chosen = only ? ids.filter((id) => only.includes(id)) : ids;

const server = Bun.serve({
  port: 0,
  async fetch(request) {
    const path = normalize(decodeURIComponent(new URL(request.url).pathname)).replace(/^(\.\.[/\\])+/, "");
    const file = Bun.file(join(galleryDir, path === "/" ? "index.html" : path));
    return (await file.exists()) ? new Response(file) : new Response("not found", { status: 404 });
  },
});
const base = `http://127.0.0.1:${server.port}`;

// System Google Chrome, as runner.ts launches it, never Playwright's bundled build.
const browser = await chromium.launch({
  headless: true,
  ...(process.env.CMUX_CHROME_HEADLESS_SHELL
    ? { executablePath: process.env.CMUX_CHROME_HEADLESS_SHELL }
    : { channel: "chrome" }),
});
const results: Record<string, unknown>[] = [];
try {
  for (const id of chosen) {
    for (const scheme of ["dark", "light"] as const) {
      const page = await browser.newPage({ viewport: { width: 1640, height: 1120 }, deviceScaleFactor: 2 });
      const query = new URLSearchParams({
        fixture: "font-study.screen/long-chat",
        fontStudy: id,
        colorScheme: scheme,
        window: values.window!,
        zoom: "1",
        loop: "0",
      });
      await page.goto(`${base}/mock-app.html?${query}`, { waitUntil: "domcontentloaded" });
      await page.waitForFunction(() => document.documentElement.dataset.mockAppReady === "1", null, { timeout: 30_000 });
      // Each pane is its own stage frame; wait until it has painted and gone still. A pane that errors or
      // never settles fails the run, so no capture of a broken pane is judged.
      for (const frame of page.frames().slice(1)) {
        await frame.waitForFunction(() => document.documentElement.dataset.galleryReady !== undefined, null, {
          timeout: 30_000,
        });
        const ready = await frame.evaluate(() => document.documentElement.dataset.galleryReady);
        if (ready !== "1") throw new Error(`${id}-${scheme}: pane ${frame.url()} is not ready (galleryReady=${ready})`);
      }
      const applied = await page.evaluate(() => ({
        chrome: getComputedStyle(document.querySelector(".app-sidebar-title") ?? document.body).fontFamily,
      }));
      const name = `${id}-${scheme}`;
      const window = page.locator(".app-window").first();
      await window.screenshot({ path: join(outputDir, `${name}-window.png`) });
      await page.locator(".app-sidebar").first().screenshot({ path: join(outputDir, `${name}-sidebar.png`) });
      await page.locator(".app-pane iframe").first().screenshot({ path: join(outputDir, `${name}-pane.png`) });
      results.push({ id, scheme, window: `${name}-window.png`, sidebar: `${name}-sidebar.png`, pane: `${name}-pane.png`, applied });
      await page.close();
      console.log(`captured ${name}`);
    }
  }
} finally {
  await browser.close();
  server.stop();
}
writeFileSync(join(outputDir, "index.json"), JSON.stringify(results, null, 2));
const rows = chosen
  .map(
    (id) =>
      `<h2>${id}</h2><div class="row">${["dark", "light"].map((scheme) => `<img src="${id}-${scheme}-window.png">`).join("")}</div>`,
  )
  .join("");
writeFileSync(
  join(outputDir, "index.html"),
  `<!doctype html><meta charset="utf-8"><title>Font study</title><style>body{font:14px system-ui;margin:24px}.row{display:flex;gap:16px}.row img{width:48%}</style>${rows}`,
);
