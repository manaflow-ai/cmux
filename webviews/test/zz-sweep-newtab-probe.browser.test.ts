// cmux-web-test-timeout: 300
// l10n-allow-file: scratch probe (class-sweep helper), deleted after the run.
import { afterAll, beforeAll, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser } from "playwright";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";
import { probeEngineOrSkip, requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("zz-sweep-newtab-probe.browser.test.ts", async () => {
  if (!(await probeEngineOrSkip("sweep probe", "chromium", chromium))) return;
  setDefaultTimeout(180_000);
  const { createServer } = await import("vite");
  let vite: Awaited<ReturnType<typeof createServer>>;
  let browser: Browser;
  beforeAll(async () => {
    vite = await createServer({
      configFile: path.resolve(import.meta.dir, "../vite.config.gallery-dev.ts"),
      server: { port: 0, host: "127.0.0.1", watch: { ignored: () => true } },
      logLevel: "error",
    });
    await vite.listen();
    browser = await chromium.launch({ headless: true });
    await warmGalleryFrame(vite, "agent-pane.new-tab", { browser, params: { variant: "wrap-one-line" } });
  });
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });
  test("new tab geometry", async () => {
    const page = await browser.newPage({ viewport: { width: 760, height: 800 } });
    const { port } = vite.httpServer!.address() as { port: number };
    await page.goto(`http://127.0.0.1:${port}${galleryFrame("agent-pane.new-tab", { variant: "wrap-one-line" })}`);
    await page.waitForFunction(() => document.documentElement.dataset.galleryReady === "1");
    await page.evaluate(() => document.fonts.ready);
    const editor = page.locator(".nt-field .ProseMirror");
    const read = () =>
      page.evaluate(() => {
        const box = document.querySelector(".nt-box")!.getBoundingClientRect();
        const field = document.querySelector<HTMLElement>(".nt-field")!;
        const p = field.querySelector(".ProseMirror")!.getBoundingClientRect();
        const r = (s: string) => document.querySelector(s)?.getBoundingClientRect();
        const plus = r(".nt-split-plus button") ?? r(".acpmux-newtab-plus button");
        const mic = r(".nt-pickers .acpmux-mic");
        const send = r(".nt-pickers .acpmux-send");
        return {
          split: !!document.querySelector(".nt-input[data-split]"),
          boxH: +box.height.toFixed(2),
          plusLeft: plus && +(plus.left - box.left).toFixed(2),
          plusToText: plus && +(p.left - plus.right).toFixed(2),
          textToMic: mic && +(mic.left - p.right).toFixed(2),
          fieldToMic: mic && +(mic.left - field.getBoundingClientRect().right).toFixed(2),
          lane: field.offsetWidth - field.clientWidth,
          sendRight: send && +(box.right - send.right).toFixed(2),
          plusBottom: plus && +(box.bottom - plus.bottom).toFixed(2),
          sendBottom: send && +(box.bottom - send.bottom).toFixed(2),
          plusTop: plus && +(plus.top - box.top).toFixed(2),
          textWidth: +p.width.toFixed(2),
          overflowY: getComputedStyle(field).overflowY,
          attrs: [...field.attributes].map((a) => a.name).filter((n) => n.startsWith("data-cmux")),
        };
      });
    const out: Record<string, unknown> = {};
    await editor.click();
    out.one = await read();
    await editor.fill("m ".repeat(160));
    await page.waitForTimeout(800);
    out.multi = await read();
    await editor.fill(Array.from({ length: 40 }, (_, i) => `line ${i + 1}`).join("\n"));
    await page.waitForTimeout(800);
    out.capped = await read();
    console.log(`SWEEP_PROBE ${JSON.stringify(out)}`);
    expect(out.one).toBeDefined();
    await page.close();
  });

  test("classic new tab row geometry", async () => {
    const pane = await createServer({
      configFile: path.resolve(import.meta.dir, "../vite.config.acpmux-pane.mjs"),
      server: { port: 0, host: "127.0.0.1", strictPort: false, watch: { ignored: () => true } },
      logLevel: "error",
    });
    await pane.listen();
    const page = await browser.newPage({ viewport: { width: 900, height: 800 } });
    try {
      await page.addInitScript(() => {
        const newTab = {
          kind: "agent",
          template: "classic",
          hotkeys: {},
          home: "/Users/you",
          cwd: "/Users/you/src/atlas-web",
          projects: ["/Users/you/src/atlas-web"],
          lastPicks: { global: { harness: "claude", model: "claude-opus-5-5" }, folders: [] },
        };
        Object.assign(window, {
          __cmuxNewTabContext: newTab,
          webkit: { messageHandlers: { agentSession: { postMessage: async () => ({ ok: true, value: null }) } } },
          cmuxAcpmuxActions: {
            ready: async () => ({ protocolVersion: 1, transport: "mock", newSession: true, newTab }),
          },
        });
      });
      const { port } = pane.httpServer!.address() as { port: number };
      await page.goto(`http://127.0.0.1:${port}/`);
      await page.locator(".acpmux-newtab-row .ProseMirror").waitFor({ timeout: 60_000 });
      const read = () =>
        page.evaluate(() => {
          const row = document.querySelector(".acpmux-newtab-row")!.getBoundingClientRect();
          const icon = document.querySelector(".acpmux-newtab-row > svg")!.getBoundingClientRect();
          const sw = document.querySelector(".acpmux-newtab-switch")!.getBoundingClientRect();
          return {
            rowH: row.height,
            iconTop: +(icon.top - row.top).toFixed(2),
            iconBottom: +(row.bottom - icon.bottom).toFixed(2),
            switchTop: +(sw.top - row.top).toFixed(2),
            switchBottom: +(row.bottom - sw.bottom).toFixed(2),
          };
        });
      const editor = page.locator(".acpmux-newtab-row .ProseMirror");
      await editor.click();
      const one = await read();
      await editor.fill(Array.from({ length: 5 }, (_, i) => `line ${i + 1}`).join("\n"));
      await page.waitForTimeout(800);
      const five = await read();
      console.log(`SWEEP_CLASSIC ${JSON.stringify({ one, five })}`);
      expect(Math.abs(one.iconTop - one.iconBottom)).toBeLessThan(1);
      expect(Math.abs(one.switchTop - one.switchBottom)).toBeLessThan(1);
      expect(five.rowH).toBeGreaterThan(one.rowH);
      expect(Math.abs(five.iconBottom - one.iconBottom)).toBeLessThan(0.5);
      expect(Math.abs(five.switchBottom - one.switchBottom)).toBeLessThan(0.5);
    } finally {
      await page.close();
      await pane.close();
    }
  });
});
