// Manual fleet regression. Deliberately outside test discovery: no new CI lane or test wiring.
// CMUX_BROWSER_TESTS=1 bun scripts/verification/transcript-chevrons.ts
import assert from "node:assert/strict";
import { mkdir } from "node:fs/promises";
import path from "node:path";
import { chromium, type Page } from "playwright";
import { createServer } from "vite";
import { galleryFrame, warmGalleryFrame } from "../../test/support/galleryFrame";

assert.equal(
  process.env.CMUX_BROWSER_TESTS,
  "1",
  "Run on the hosted browser lane with CMUX_BROWSER_TESTS=1",
);
const webviews = path.resolve(import.meta.dir, "../..");
const captures = process.env.CMUX_CHEVRON_CAPTURE_DIR;
if (captures) await mkdir(captures, { recursive: true });
const vite = await createServer({
  configFile: path.join(webviews, "vite.config.gallery-dev.ts"),
  server: { port: 0, host: "127.0.0.1", strictPort: false },
  logLevel: "error",
});
const browser = await chromium.launch({ headless: true });
const failures: string[] = [];
let measured = 0;
const entry = "agent-pane.transcript-chevrons";
const glyphs =
  ".cv-tool__chevron, .cv-worked__chevron, .cv-received__toggle > .cv-rotor, .cv-received__more > .cv-rotor, .cv-subsession__toggle > .cv-rotor, .cv-subagents > :last-child";

async function measure(page: Page, label: string) {
  const result = await page.locator("[data-chevron-column]").evaluate((box, selector) => {
    const rtl = getComputedStyle(box).direction === "rtl";
    const b = box.getBoundingClientRect();
    const errors: string[] = [];
    const rect = (node: Element) => node.getBoundingClientRect();
    const overlap = (a: DOMRect, c: DOMRect) =>
      Math.min(a.right, c.right) - Math.max(a.left, c.left) > 0.5 &&
      Math.min(a.bottom, c.bottom) - Math.max(a.top, c.top) > 0.5;
    const controls = [...box.querySelectorAll(selector)].filter((node) => {
      const style = getComputedStyle(node);
      return style.visibility !== "hidden" && rect(node).width > 0;
    });
    for (const glyph of controls) {
      const g = rect(glyph);
      const name = glyph.closest("[data-case]")?.getAttribute("data-case");
      const inset = rtl ? g.left - b.left : b.right - g.right;
      if (Math.abs(inset) > 0.5) errors.push(`${name}: trailing inset ${inset.toFixed(2)}`);
      const line = glyph.closest(".cv-agentmsg__line, .cv-received__line, button, summary")!;
      for (const part of line.querySelectorAll(
        ".cv-tool__text, .cv-command__text, .cv-thought__label, .cv-agentmsg__preview, .cv-received__preview, .cv-command__meta, .cv-sent-actions, .cv-received-actions, .cv-received__reply",
      )) {
        if (!part.contains(glyph) && overlap(rect(part), g))
          errors.push(`${name}: glyph overlaps ${part.className}`);
      }
    }
    for (const line of box.querySelectorAll(".cv-agentmsg__line, .cv-received__line")) {
      const preview = line.querySelector(".cv-agentmsg__preview, .cv-received__preview");
      if (!preview) continue;
      for (const action of line.querySelectorAll(
        ".cv-sent-actions, .cv-received-actions, .cv-received__reply, .cv-command__meta",
      )) {
        if (overlap(rect(preview), rect(action))) errors.push("message preview overlaps actions");
      }
    }
    const command = box.querySelector("[data-case=command-copy]")!;
    const copy = command.querySelector(".acpmux-row__copy")!;
    for (const part of command.querySelectorAll(
      ".cv-command__text, .cv-command__meta, .cv-tool__chevron",
    )) {
      if (overlap(rect(copy), rect(part))) errors.push(`floating Copy overlaps ${part.className}`);
    }
    if (box.scrollWidth > box.clientWidth + 1) errors.push("transcript overflows inline");
    if (box.querySelector("[data-case=text-disclosure] svg, .cv-tool-group__more svg"))
      errors.push("text-only disclosure gained a chevron");
    return { controls: controls.length, errors };
  }, glyphs);
  assert.ok(result.controls >= 10, `${label}: expected real expandable rows to render`);
  measured += result.controls;
  failures.push(...result.errors.map((error) => `${label}: ${error}`));
}

try {
  await vite.listen();
  await warmGalleryFrame(vite, entry, { browser, params: { variant: "ltr" } });
  const port = (vite.httpServer!.address() as { port: number }).port;
  for (const width of [420, 760])
    for (const variant of ["ltr", "rtl", "minimal-ltr", "minimal-rtl"])
      for (const colorScheme of ["light", "dark"] as const) {
        const page = await browser.newPage({
          viewport: { width, height: 1200 },
          reducedMotion: "reduce",
          colorScheme,
        });
        const label = `${width}-${variant}-${colorScheme}`;
        await page.goto(`http://127.0.0.1:${port}${galleryFrame(entry, { variant, colorScheme })}`);
        await page.locator("[data-case=text-disclosure] button").waitFor();
        if (captures)
          await page.screenshot({
            path: path.join(captures, `${label}-closed.png`),
            fullPage: true,
          });
        await measure(page, `${label}-closed`);
        for (const name of [
          "tool-short",
          "tool-long-failed",
          "group-closed",
          "thought",
          "sent-short",
          "sent-long",
          "received",
          "subagent",
          "worked",
        ]) {
          const control = page.locator(`[data-case=${name}] button[aria-expanded]`).first();
          const before = await control.getAttribute("aria-expanded");
          await control.focus();
          await page.keyboard.press("Enter");
          assert.notEqual(
            await control.getAttribute("aria-expanded"),
            before,
            `${label}/${name}: keyboard toggle`,
          );
        }
        await page.locator(".cv-received__more").waitFor();
        if (captures)
          await page.screenshot({ path: path.join(captures, `${label}-open.png`), fullPage: true });
        await measure(page, `${label}-open`);
        await page.close();
      }
  console.log(JSON.stringify({ measured, failures }, null, 2));
  assert.deepEqual(
    failures,
    [],
    "All visible expansion glyphs must share the content-box edge without overlap",
  );
} finally {
  await browser.close();
  await vite.close();
}
