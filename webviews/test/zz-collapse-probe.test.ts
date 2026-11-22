// l10n-allow-file: temporary probe.
import { afterAll, beforeAll, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser } from "playwright";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";
const ENTRY = "agent-pane.zz-collapse-probe";
setDefaultTimeout(300_000);
const { createServer } = await import("vite");
const webviews = path.resolve(import.meta.dir, "..");
let vite: Awaited<ReturnType<typeof createServer>> | undefined;
let browser: Browser;
beforeAll(async () => {
  vite = await createServer({
    configFile: path.join(webviews, "vite.config.gallery-dev.ts"),
    server: { port: 0, host: "127.0.0.1" },
    logLevel: "error",
  });
  await vite.listen();
  browser = await chromium.launch({ headless: true });
  for (let a = 1; ; a++)
    try {
      await warmGalleryFrame(vite, ENTRY, { browser, params: { variant: "typed-1" } });
      break;
    } catch (e) {
      if (a >= 3) throw e;
    }
});
afterAll(async () => {
  await browser?.close();
  await vite?.close();
});
const variants = (process.env.PROBE ?? "typed-1,typed-5,typed-15,typed-40,pasted-15,pasted-40,pasted-200").split(",");
for (const variant of variants)
  test(variant, async () => {
    for (let run = 0; run < Number(process.env.RUNS ?? 3); run++) {
      const page = await browser.newPage({ viewport: { width: 1000, height: 800 } });
      const port = (vite!.httpServer!.address() as { port: number }).port;
      const cdp = await page.context().newCDPSession(page);
      await cdp.send("Profiler.enable");
      await cdp.send("Profiler.setSamplingInterval", { interval: 200 });
      cdp.on("Profiler.consoleProfileFinished", (ev: any) => {
        require("node:fs").writeFileSync(`/tmp/probe/${variant}-${run}.cpuprofile`, JSON.stringify(ev.profile));
      });
      await page.goto(`http://127.0.0.1:${port}${galleryFrame(ENTRY, { variant, width: 900 })}`);
      await page.waitForFunction(() => document.documentElement.dataset.galleryReady !== undefined, undefined, {
        timeout: 180_000,
      });
      const r = await page.evaluate(
        () => document.documentElement.dataset.probe ?? JSON.stringify((window as any).cmuxGalleryPlayReport?.status),
      );
      console.log(`PROBE ${variant} run${run} ${r}`);
      await page.close();
    }
  });
