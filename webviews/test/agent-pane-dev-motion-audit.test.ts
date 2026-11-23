import { expect, test } from "bun:test";
import { build } from "esbuild";
import { chromium } from "playwright";
import { requireBrowserLane } from "./support/requireBrowserLane";

type AuditProbeResult = { viteEnv: string; nightly: boolean; dev: boolean };

await requireBrowserLane("agent-pane-dev-motion-audit", async () => {
  test("the native pane can start without Vite's environment object", async () => {
    // The native pane ships browser ESM from esbuild, without a Vite environment.
    const bundle = await build({
      bundle: true,
      platform: "browser",
      format: "esm",
      target: "es2022",
      write: false,
      loader: { ".woff2": "dataurl" },
      stdin: {
        resolveDir: import.meta.dir,
        contents: `
          import { startDevMotionAudit } from "../src/agent-session/acpmux/devMotionAudit";
          window.probeMotionAudit = () => {
            startDevMotionAudit("cmux-nightly");
            const nightly = Boolean(window.cmuxMotionAudit);
            startDevMotionAudit("cmux-dev-fixture");
            const dev = Boolean(window.cmuxMotionAudit);
            window.cmuxMotionAudit?.stop();
            return { viteEnv: typeof import.meta.env, nightly, dev };
          };
        `,
      },
    });
    const browser = await chromium.launch({ headless: true });
    try {
      const page = await browser.newPage();
      await page.addScriptTag({ type: "module", content: bundle.outputFiles[0].text });
      await page.waitForFunction(() => "probeMotionAudit" in window);
      expect(await page.evaluate<AuditProbeResult>("window.probeMotionAudit()")).toEqual({
        viteEnv: "undefined",
        nightly: false,
        dev: true,
      });
    } finally {
      await browser.close();
    }
  });
});
