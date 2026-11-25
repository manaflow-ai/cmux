// l10n-allow-file: measurement tool, no shipped UI.
// The computed corner of every composer-family element (the box, the strip, the queue, the hat, the asks
// stack and its trust bar, New Tab's composer, attachments), per placement: the mock app's real agent pane
// under every golden look at each density, and the gallery's composer, quick panel, trust bar, New Tab and
// stand-in states. Run it on a base and on a head and diff the two files: a radius refactor that draws
// nothing new shows no line of difference (RFD 0116 strict fix 10).
//
//   bun scripts/gallery/composer-radii.ts [OUT.json]
// On a lane VM: `cmux-ci test -- bash -c 'cd webviews && bun scripts/gallery/composer-radii.ts "$FAST_CHECKS_OUT/radii.json"'`.
import { writeFileSync } from "node:fs";
import path from "node:path";
import { chromium } from "playwright";

const webviews = path.resolve(import.meta.dir, "../..");
const out = process.argv[2] ?? "/tmp/composer-radii.json";
const { readGoldenLooks } = await import("../../dev-server/goldenLooks");
const looks = readGoldenLooks().looks.map((look) => look.id);
const { createServer } = await import("vite");
const vite = await createServer({
  configFile: path.join(webviews, "vite.config.gallery-dev.ts"),
  server: { port: 0, host: "127.0.0.1" },
  logLevel: "error",
});
await vite.listen();
const port = (vite.httpServer!.address() as { port: number }).port;
const browser = await chromium.launch({ headless: true, channel: "chrome" }).catch(() => chromium.launch());
const FAMILY =
  "composer|asks-stack|trust-ask|acpmux-dock|tray|goal|strip|queue|drop|attach|nt-|permission|question|quick";

/** Every family element's four corners and the two radius tokens it sees, keyed by its tag, classes and index. */
function collect(family: string): Record<string, string> {
  const match = new RegExp(family);
  const radii: Record<string, string> = {};
  const seen: Record<string, number> = {};
  for (const el of document.querySelectorAll("*")) {
    const cls = typeof el.className === "string" ? el.className.trim() : "";
    if (!match.test(cls)) continue;
    const cs = getComputedStyle(el);
    const key = `${el.tagName.toLowerCase()}.${cls.split(/\s+/).join(".")}`;
    const n = (seen[key] = (seen[key] ?? 0) + 1);
    radii[`${key}#${n}`] = [
      cs.borderTopLeftRadius,
      cs.borderTopRightRadius,
      cs.borderBottomRightRadius,
      cs.borderBottomLeftRadius,
    ].join(" ");
  }
  return radii;
}

const result: Record<string, Record<string, string>> = {};
const page = await (await browser.newContext({ viewport: { width: 1400, height: 1800 } })).newPage();
for (const look of looks)
  for (const density of ["compact", "comfortable", "spacious"]) {
    const name = `mock-app ${look} ${density}`;
    const query = new URLSearchParams({
      fixture: `looks.golden/${look}`,
      colorScheme: "light",
      window: "1280x1600",
      zoom: "1",
      density,
    });
    try {
      for (let attempt = 1; ; attempt += 1) {
        try {
          await page.goto(`http://127.0.0.1:${port}/gallery/mock-app.html?${query}`);
          await page.waitForSelector('html[data-mock-app-ready="1"]', {
            timeout: 120_000,
          });
          break;
        } catch (error) {
          if (attempt >= 4) throw error;
        }
      }
      const frame = page.frames().find((candidate) => candidate.url().includes("frame.html"))!;
      await frame.waitForSelector(".acpmux-composer-box", { timeout: 60_000 });
      await page.waitForTimeout(1000);
      result[name] = await frame.evaluate(collect, FAMILY);
    } catch (error) {
      result[name] = { error: String(error).split("\n")[0]! };
    }
  }
const ENTRIES: [string, string][] = [
  ["agent-pane.composer", "idle"],
  ["agent-pane.composer", "working-queue"],
  ["agent-pane.composer", "tray-long-branch"],
  ["agent-pane.composer", "new-chat"],
  ["agent-pane.composer", "image-attached"],
  ["agent-pane.quick-surface", "empty"],
  ["agent-pane.quick-surface", "waiting"],
  ["agent-pane.quick-surface", "floating"],
  ["agent-pane.trust-ask", "grid-ask"],
  ["agent-pane.new-tab", "start-refused"],
  ["agent-pane.managed-banner-designs", "sending"],
  ["agent-pane.compound-motion", ""],
];
for (const [entry, variant] of ENTRIES) {
  const query = new URLSearchParams({
    entry,
    colorScheme: "light",
    width: "normal",
    frame: "component",
  });
  if (variant) query.set("variant", variant);
  const name = `${entry}/${variant}`;
  try {
    await page.goto(`http://127.0.0.1:${port}/gallery/frame.html?${query}`, {
      waitUntil: "domcontentloaded",
    });
    await page.waitForFunction(() => document.documentElement.dataset.galleryReady === "1", undefined, {
      timeout: 90_000,
    });
    await page.waitForTimeout(800);
    result[name] = await page.evaluate(collect, FAMILY);
  } catch (error) {
    result[name] = { error: String(error).split("\n")[0]! };
  }
}
writeFileSync(out, JSON.stringify(result, null, 1));
await browser.close();
await vite.close();
console.log(`composer-radii: ${Object.keys(result).length} placements -> ${out}`);
process.exit(0);
