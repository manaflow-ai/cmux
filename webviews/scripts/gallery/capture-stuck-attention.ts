// l10n-allow-file: synthetic gallery evidence; no product strings.
// Fleet-only after `bun run gallery:build`. The gallery plays each real-pane interaction first.
import { mkdir, writeFile } from "node:fs/promises";
import path from "node:path";
import assert from "node:assert/strict";
import { chromium } from "playwright";
import type { PlayReport } from "../../src/gallery/play";

const output = process.env.FAST_CHECKS_OUT;
if (!output) throw new Error("FAST_CHECKS_OUT must name the fleet artifact directory");
const gallery = path.resolve(import.meta.dir, "../../dist/gallery");
const out = path.join(output, "stuck-attention");
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
const variants = [
  "loop-ring",
  "silent-ring",
  "nudge-edit",
  "clears-on-progress",
  "attention-transition",
  "quick-loop-ring",
];
const layouts = [
  { name: "dark-normal-reduced", width: 900, scheme: "dark", reducedMotion: true },
  { name: "light-normal-reduced", width: 900, scheme: "light", reducedMotion: true },
  { name: "dark-narrow-reduced", width: 420, scheme: "dark", reducedMotion: true },
  { name: "dark-normal-motion", width: 900, scheme: "dark", reducedMotion: false },
  { name: "light-normal-motion", width: 900, scheme: "light", reducedMotion: false },
  { name: "dark-narrow-motion", width: 420, scheme: "dark", reducedMotion: false },
] as const;
const results: Array<Record<string, unknown>> = [];
try {
  const browser = await chromium.launch({ headless: true });
  try {
    for (const layout of layouts)
      for (const variant of variants) {
        const context = await browser.newContext({
          viewport: { width: layout.width, height: 720 },
          deviceScaleFactor: 2,
          reducedMotion: layout.reducedMotion ? "reduce" : "no-preference",
          colorScheme: layout.scheme,
        });
        const page = await context.newPage();
        try {
          const params = new URLSearchParams({
            entry: "agent-pane.stuck-attention",
            variant,
            source: "src/agent-session/acpmux/StuckAgentPane.gallery.ts",
            entryPath: "src/agent-session/acpmux/StuckAgentPane.gallery.ts",
            theme: layout.scheme === "light" ? "Apple System Colors Light" : "Apple System Colors",
            colorScheme: layout.scheme,
            reducedMotion: String(layout.reducedMotion),
            width: String(layout.width),
            height: "720",
          });
          await page.goto(`http://127.0.0.1:${server.port}/frame.html?${params}`, { waitUntil: "domcontentloaded" });
          await page.waitForFunction(() => document.documentElement.dataset.galleryReady === "1", undefined, {
            timeout: 30_000,
          });
          await page.evaluate(() => document.fonts.ready);
          const readback = await page.evaluate(() => {
            const pane = document.querySelector<HTMLElement>(".acpmux-main, .acpmux-shell[data-surface='quick']");
            const composer = document.querySelector<HTMLElement>(".acpmux-composer-box");
            const draft = document.querySelector<HTMLElement>(".acpmux-composer-box [contenteditable='true']");
            const rect = composer?.getBoundingClientRect();
            const banner = document.querySelector<HTMLElement>(".acpmux-stuck-banner");
            const action = banner?.querySelector<HTMLElement>(".acpmux-stuck-nudge");
            const visible = (element: HTMLElement | null | undefined) => {
              if (!element) return null;
              const box = element.getBoundingClientRect();
              return (
                box.left >= -0.5 &&
                box.top >= -0.5 &&
                box.right <= innerWidth + 0.5 &&
                box.bottom <= innerHeight + 0.5 &&
                box.width > 0 &&
                box.height > 0
              );
            };
            const calls = (window as unknown as { cmuxGalleryLog?: { method: string }[] }).cmuxGalleryLog ?? [];
            const playReport = (window as unknown as { cmuxGalleryPlayReport?: PlayReport }).cmuxGalleryPlayReport;
            return {
              stuck: pane?.hasAttribute("data-stuck") ?? false,
              ring: pane ? getComputedStyle(pane, "::after").borderTopWidth : "missing",
              diagnosis: document.querySelector(".acpmux-stuck-banner")?.textContent ?? null,
              bannerVisible: visible(banner),
              actionVisible: visible(action),
              draft: draft?.textContent ?? "",
              composer: rect && { x: rect.x, y: rect.y, width: rect.width, height: rect.height },
              sendOrCancel: calls.filter(({ method }) => method === "chat.send" || method === "chat.cancel").length,
              playReport,
              stageErrors: document.querySelectorAll(".error").length,
              stageErrorText: Array.from(document.querySelectorAll(".error"), (element) => element.textContent).join(
                "\n",
              ),
              source: document.documentElement.dataset.gallerySource,
              revision: document.documentElement.dataset.galleryRevision,
              reducedMotion: matchMedia("(prefers-reduced-motion: reduce)").matches,
            };
          });
          // Keep the failing variant's state even when a play assertion fails. The packet and image
          // identify whether the real composer, gallery driver, or attention transition regressed.
          await page.screenshot({ path: path.join(out, `${variant}-${layout.name}.png`), fullPage: false });
          results.push({ variant, layout: layout.name, ...readback });
          assert.equal(readback.reducedMotion, layout.reducedMotion, `${variant}: motion environment`);
          assert.ok(readback.composer, `${variant}: real composer missing`);
          assert.ok(readback.playReport, `${variant}: gallery play did not run`);
          assert.notEqual(
            readback.playReport.status,
            "fail",
            `${variant}: gallery play failed: ${JSON.stringify(readback.playReport)}`,
          );
          assert.equal(readback.stageErrors, 0, `${variant}: gallery stage error`);
          assert.equal(readback.stuck, variant !== "clears-on-progress", `${variant}: attention state`);
          assert.equal(readback.sendOrCancel, 0, `${variant}: agent was sent or cancelled`);
          if (variant !== "clears-on-progress") {
            assert.equal(readback.bannerVisible, true, `${variant} ${layout.name}: diagnosis outside viewport`);
            assert.equal(readback.actionVisible, true, `${variant} ${layout.name}: nudge outside viewport`);
          }
          if (variant === "nudge-edit" || variant === "clears-on-progress")
            assert.match(
              readback.draft,
              /Check the auth regression too\..*smaller auth fixture/s,
              `${variant}: draft not preserved and editable`,
            );
          if (variant === "loop-ring" || variant === "attention-transition" || variant === "quick-loop-ring")
            assert.match(readback.diagnosis ?? "", /auth\.rs:88/, `${variant}: loop diagnosis`);
        } finally {
          await context.close();
        }
      }
  } finally {
    await browser.close();
  }
} finally {
  await server.stop();
  await writeFile(path.join(out, "readback.json"), JSON.stringify(results, null, 2));
}
assert.equal(results.length, variants.length * layouts.length);
console.log(`${results.length} real-pane gallery captures and readbacks in ${out}`);
