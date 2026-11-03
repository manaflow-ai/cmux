// l10n-allow-file: gallery measurement diagnostics and synthetic fixtures.
// Run on the fleet: bun run bench/permission-card-estimates.ts.
import { mkdir, writeFile } from "node:fs/promises";
import path from "node:path";
import { chromium } from "playwright";
import { createServer } from "vite";
import { refusePlaywrightOnMacs, useSystemChrome } from "../test/support/systemChrome";
import { galleryFrame, warmGalleryFrame } from "../test/support/galleryFrame";

const root = path.resolve(import.meta.dir, "..");
const server = await createServer({
  configFile: path.join(root, "vite.config.gallery-dev.ts"),
  server: { port: 0, host: "127.0.0.1", strictPort: false },
  logLevel: "error",
});
refusePlaywrightOnMacs([chromium]);
useSystemChrome(chromium);
const browser = await chromium.launch({ headless: true });
const results: { entry: string; scheme: string; width: number; drawn: number; before: number; after: number }[] = [];
try {
  await server.listen();
  const { port } = server.httpServer!.address() as { port: number };
  for (const [entry, variant, file, selector] of [
    ["agent-pane.permission-card", "grid-transcript", "PermissionCard.gallery.tsx", ".acpmux-permission-ask"],
    ["agent-pane.question-card", "pending-single", "question/QuestionCard.gallery.tsx", ".acpmux-question-ask"],
  ]) {
    await warmGalleryFrame(server, entry!, { browser, params: { variant } });
    for (const scheme of ["dark", "light"] as const)
      for (const width of [360, 720]) {
        const page = await browser.newPage({ viewport: { width, height: 900 }, deviceScaleFactor: 2 });
        try {
          await page.goto(`http://127.0.0.1:${port}${galleryFrame(entry!, { variant, colorScheme: scheme })}`);
          await page.locator(selector!).waitFor();
          await page.evaluate(() => document.fonts.ready);
          const result = await page.evaluate(
            async ({ file, variant, selector }) => {
              const base = "/src/agent-session/acpmux/";
              const [{ default: entry }, { permissionCardHeight }] = await Promise.all([
                import(base + file),
                import(base + "permissions/cardHeight.ts"),
              ]);
              const props = entry.variants[variant].props;
              const box = document.querySelector(selector)!.getBoundingClientRect();
              const permission = props.permission ?? { question: props.question };
              return { drawn: box.height, before: 87, after: permissionCardHeight(permission, box.width) };
            },
            { file: file!, variant: variant!, selector: selector! },
          );
          results.push({ entry: entry!, scheme, width, ...result });
          if (process.env.FAST_CHECKS_OUT) {
            await mkdir(process.env.FAST_CHECKS_OUT, { recursive: true });
            await page
              .locator(selector!)
              .screenshot({ path: path.join(process.env.FAST_CHECKS_OUT, `${entry}-${scheme}-${width}.png`) });
          }
        } finally {
          await page.close();
        }
      }
  }
} finally {
  await browser.close();
  await server.close();
}
console.log(JSON.stringify(results, null, 2));
if (process.env.FAST_CHECKS_OUT)
  await writeFile(
    path.join(process.env.FAST_CHECKS_OUT, "permission-estimates.json"),
    JSON.stringify(results, null, 2),
  );
if (results.some(({ drawn, after }) => Math.abs(drawn - after) > 2))
  throw new Error("A permission/question first-layout estimate differs from its gallery by more than 2px");
