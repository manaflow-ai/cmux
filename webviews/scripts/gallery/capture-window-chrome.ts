// l10n-allow-file: synthetic review gallery evidence, no product wiring.
// Run on the fleet after gallery:build; writes 2x captures and actual DOM geometry.
import { mkdir, writeFile } from "node:fs/promises";
import path from "node:path";
import assert from "node:assert/strict";
import { chromium, webkit } from "playwright";
import {
  assertChromeHeaderGeometry,
  measureChromeHeaderGeometry,
  type ChromeHeaderGeometry,
} from "../../src/gallery/fixtures/ChromeHeaderMenus.geometry";

const output = process.env.FAST_CHECKS_OUT;
if (!output) throw new Error("FAST_CHECKS_OUT must name the fleet artifact directory");
const gallery = path.resolve(import.meta.dir, "../../dist/gallery");
const out = path.join(output, "window-chrome-final");
await mkdir(out, { recursive: true });
const server = Bun.serve({
  port: 0,
  async fetch(request) {
    const name = decodeURIComponent(new URL(request.url).pathname).replace(/^\/+/, "");
    const file = path.resolve(gallery, name || "index.html");
    if (!file.startsWith(`${gallery}/`)) return new Response("forbidden", { status: 403 });
    const blob = Bun.file(file);
    return (await blob.exists()) ? new Response(blob) : new Response("not found", { status: 404 });
  },
});
const scenes = [
  "one-zen",
  "one-zen-hover",
  "one-visible",
  "three-zen",
  "one-always-strip",
  "one-title-menu",
  "three-pane-menu",
  "three-developer-menu",
];
const cases = ["recommendation", "group-line", "aside-labels", "rex-icons"].flatMap((shape) =>
  ["compact", "comfortable"].flatMap((density) =>
    ["light", "dark"].map((scheme) => ({ variant: `${shape}-${density}-${scheme}`, density, scheme })),
  ),
);
for (const scene of scenes)
  for (const density of ["compact", "comfortable"])
    for (const scheme of ["light", "dark"])
      cases.push({ variant: `recommendation-${density}-${scheme}-${scene}`, density, scheme });
const results: Array<
  {
    variant: string;
    engine: string;
    before: ChromeHeaderGeometry;
    hoverFocusDelta: number;
    readback: { rowHeight: number };
  } & Record<string, unknown>
> = [];
try {
  for (const engine of ["chromium", "webkit"] as const) {
    const browser = await (engine === "chromium"
      ? chromium.launch({ channel: "chrome", headless: true })
      : webkit.launch({ headless: true }));
    try {
      const baseline = new Map<string, ChromeHeaderGeometry>();
      for (const item of cases) {
        const context = await browser.newContext({
          viewport: { width: 1360, height: 860 },
          deviceScaleFactor: 2,
          colorScheme: item.scheme as "light" | "dark",
          reducedMotion: "reduce",
        });
        const page = await context.newPage();
        try {
          const params = new URLSearchParams({
            entry: "native.window-chrome-shapes",
            variant: item.variant,
            source: "src/gallery/fixtures/WindowChromeShape.gallery.tsx",
            entryPath: "src/gallery/fixtures/WindowChromeShape.gallery.tsx",
            frame: "component",
            theme: item.scheme === "light" ? "Apple System Colors Light" : "Apple System Colors",
            colorScheme: item.scheme,
            width: "1360",
            height: "860",
          });
          await page.goto(`http://127.0.0.1:${server.port}/frame.html?${params}`, { waitUntil: "domcontentloaded" });
          await page.waitForFunction(() => document.documentElement.dataset.galleryReady === "1", undefined, {
            timeout: 30_000,
          });
          await page.evaluate(() => document.fonts.ready);
          assert.equal(await page.locator(".sidebar-shape__trail .cv-spinner").count(), 1);
          if (item.variant.startsWith("rex-icons-"))
            assert.equal(await page.locator(".sidebar-shape__icon svg[data-icon]").count(), 8);
          const agent = page.locator('.chrome-header-menu-fixture[data-pane-kind="agent"]');
          const browserHeader = page.locator('.chrome-header-menu-fixture[data-pane-kind="browser"]');
          const measure = async () => agent.evaluate(measureChromeHeaderGeometry);
          const before = await measure();
          const browserBox = await browserHeader.locator(".chrome-header-menu-row").boundingBox();
          const agentBox = await agent.locator(".chrome-header-menu-row").boundingBox();
          assert.ok(browserBox && agentBox);
          assert.ok(
            Math.abs(agentBox.y + agentBox.height / 2 - browserBox.y - browserBox.height / 2) <= 0.5,
            "agent/browser tab center line drift",
          );
          await agent.locator(".chrome-header-menu-row").hover();
          const hovered = await measure();
          assertChromeHeaderGeometry(before, hovered, 0.5);
          await agent.locator('[data-chrome-trigger="pane"]').focus();
          const focused = await measure();
          assertChromeHeaderGeometry(before, focused, 0.5);
          const dimensions = [
            "width",
            "height",
            "addCenterX",
            "addCenterY",
            "addTrailingInset",
            "addWidth",
            "actionWidth",
          ] as const;
          const hoverFocusDelta = Math.max(
            ...[hovered, focused].flatMap((state) => dimensions.map((key) => Math.abs(before[key] - state[key]))),
          );
          const key = `${item.density}-${item.scheme}`;
          if (baseline.has(key)) assertChromeHeaderGeometry(baseline.get(key)!, before, 0.5);
          else baseline.set(key, before);
          await page.mouse.move(0, 0);
          await page.evaluate(() => (document.activeElement as HTMLElement)?.blur());
          const readback = await page.evaluate(() => {
            const root = document.documentElement;
            const sidebar = document.querySelector(".chrome-sidebar")!;
            const body = document.querySelector(".chrome-window-body")!;
            const label = document.querySelector(".sidebar-shape__label")!;
            const members = document.querySelector(".sidebar-shape__members")!;
            const sidebarStyle = getComputedStyle(sidebar);
            return {
              sha: root.dataset.galleryRevision,
              source: root.dataset.gallerySource,
              scheme: root.dataset.theme,
              sidebarRadius: sidebarStyle.borderTopLeftRadius,
              bodyRadius: getComputedStyle(body).borderTopLeftRadius,
              rowHeight: document.querySelector(".sidebar-shape__row")!.getBoundingClientRect().height,
              sidebarColor: sidebarStyle.color,
              labelColor: getComputedStyle(label).color,
              labelLine: getComputedStyle(label).borderInlineStartColor,
              memberLine: getComputedStyle(members, "::before").backgroundColor,
              developerOpen: !!document.querySelector('[data-chrome-menu="developer"]'),
            };
          });
          assert.equal(readback.scheme, item.scheme);
          assert.equal(readback.sidebarRadius, "0px");
          assert.equal(readback.bodyRadius, "0px");
          if (item.variant.includes("group-line")) assert.equal(readback.labelLine, readback.memberLine);
          if (item.variant.includes("developer-menu")) assert.equal(readback.developerOpen, true);
          await page
            .locator(".window-chrome-gallery")
            .screenshot({ path: path.join(out, `${item.variant}-${engine}.png`) });
          await page.screenshot({
            path: path.join(out, `${item.variant}-${engine}-chrome.png`),
            clip: { x: 0, y: 0, width: 1360, height: 280 },
          });
          results.push({
            ...item,
            engine,
            before,
            hovered,
            focused,
            hoverFocusDelta,
            readback,
            params: Object.fromEntries(params),
          });
          console.log(`${item.variant} ${engine}: center line and reserved slots PASS`);
        } finally {
          await context.close();
        }
      }
    } finally {
      await browser.close();
    }
  }
} finally {
  await server.stop();
  await writeFile(path.join(out, "geometry.json"), JSON.stringify(results, null, 2));
  await writeFile(
    path.join(out, "geometry.md"),
    `| State | Engine | Header height | Add center X | Add center Y | Row height | Hover/focus delta |\n|---|---|---:|---:|---:|---:|---:|\n` +
      results
        .map(
          (r) =>
            `| ${r.variant} | ${r.engine} | ${r.before.height} | ${r.before.addCenterX} | ${r.before.addCenterY} | ${r.readback.rowHeight} | ${r.hoverFocusDelta} |`,
        )
        .join("\n"),
  );
}
assert.equal(results.length, 96);
console.log(`96 geometry cases and 192 2x images in ${out}`);
