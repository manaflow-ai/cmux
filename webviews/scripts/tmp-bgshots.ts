import path from "node:path";
import { chromium } from "playwright";
import { galleryFrame, warmGalleryFrame } from "../test/support/galleryFrame";

const [out, tag, ...picks] = process.argv.slice(2);
type Shot = {
  name: string;
  entry: string;
  variant: string;
  frame?: string;
  arm?: string;
  scheme?: string;
  w: number;
  h: number;
};
const shots: Shot[] = [];
const OLD = [
  ["card-no-output", "agent-pane.background-task-card", "running-no-output"],
  ["card-output", "agent-pane.background-task-card", "running-output"],
  ["card-finished", "agent-pane.background-task-card", "finished-collapsed"],
] as const;
for (const [name, entry, variant] of OLD)
  for (const scheme of ["dark", "light"])
    shots.push({ name: `${tag}-${name}-${scheme}`, entry, variant, frame: "component", scheme, w: 520, h: 640 });
for (const variant of ["tab", "transcript"])
  shots.push({
    name: `${tag}-panel-${variant}`,
    entry: "agent-pane.background-tasks",
    variant,
    scheme: "dark",
    w: 1100,
    h: 760,
  });
if (tag === "after")
  for (const arm of ["glyphs", "rule", "tile"])
    for (const variant of ["list", "hover-actions", "drill-in", "idle"])
      for (const scheme of arm === "glyphs" ? ["dark", "light"] : ["dark"])
        shots.push({
          name: `${tag}-rows-${arm}-${variant}-${scheme}`,
          entry: "agent-pane.background-tasks-rows",
          variant,
          frame: "component",
          arm,
          scheme,
          w: 520,
          h: 680,
        });

const { createServer } = await import("vite");
const vite = await createServer({
  configFile: path.resolve("vite.config.gallery-dev.ts"),
  server: { port: 0, host: "127.0.0.1", strictPort: false },
  logLevel: "error",
});
await vite.listen();
const browser = await chromium.launch({ headless: true });
const base = `http://127.0.0.1:${(vite.httpServer!.address() as { port: number }).port}`;
const seen = new Set<string>();
for (const shot of shots) {
  if (picks.length && !picks.some((p) => shot.name.includes(p))) continue;
  if (!seen.has(shot.entry)) {
    seen.add(shot.entry);
    await warmGalleryFrame(vite, shot.entry, { browser, params: { variant: shot.variant } }).catch((e) =>
      console.log("warm failed", shot.entry, String(e).slice(0, 200)),
    );
  }
  const page = await browser.newPage({ viewport: { width: shot.w, height: shot.h }, deviceScaleFactor: 2 });
  try {
    await page.goto(
      base +
        galleryFrame(shot.entry, {
          variant: shot.variant,
          frame: shot.frame,
          colorScheme: shot.scheme,
          arm: shot.arm,
          exp: shot.arm ? "background-tasks-rows" : undefined,
        }),
    );
    await page.waitForFunction(
      () => ["1", "error"].includes(document.documentElement.dataset.galleryReady ?? ""),
      undefined,
      { timeout: 90_000 },
    );
    await page.waitForTimeout(800);
    await page.screenshot({ path: path.join(out, `${shot.name}.png`) });
    console.log("shot", shot.name, await page.evaluate(() => document.documentElement.dataset.galleryReady));
  } catch (error) {
    console.log("FAILED", shot.name, String(error).slice(0, 300));
  } finally {
    await page.close();
  }
}
await browser.close();
await vite.close();
