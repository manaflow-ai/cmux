// cmux-web-test-timeout: 300
// TEMPORARY diagnostic for lane/rac-remaining-3; removed before the PR leaves draft.
import { afterAll, beforeAll, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, webkit, type Browser } from "playwright";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("zz-rac3-probe.browser.test.ts", async () => {
  setDefaultTimeout(240_000);
  const { createServer } = await import("vite");
  let vite: Awaited<ReturnType<typeof createServer>>;
  const browsers = new Map<string, Browser>();
  beforeAll(async () => {
    vite = await createServer({
      configFile: path.resolve(import.meta.dir, "../vite.config.gallery-dev.ts"),
      server: { port: 0, host: "127.0.0.1", strictPort: false },
      logLevel: "error",
    });
    await vite.listen();
    browsers.set("chromium", await chromium.launch({ headless: true }));
    browsers.set("webkit", await webkit.launch({ headless: true }));
    await warmGalleryFrame(vite, "agent-pane.composer", {
      browser: browsers.get("chromium"),
      params: { variant: "picker-toggle" },
    });
    await warmGalleryFrame(vite, "agent-pane.model-picker", {
      browser: browsers.get("chromium"),
      params: { variant: "quick-menu" },
    });
  });
  afterAll(async () => {
    for (const browser of browsers.values()) await browser.close();
    await vite?.close();
  });
  const port = () => (vite.httpServer!.address() as { port: number }).port;

  for (const engine of ["chromium", "webkit"])
    test(`PROBE ${engine} picker edges`, async () => {
      const page = await browsers.get(engine)!.newPage({ viewport: { width: 760, height: 600 } });
      await page.goto(
        `http://127.0.0.1:${port()}${galleryFrame("agent-pane.composer", { variant: "picker-toggle", frame: "component", width: 760, theme: "Catppuccin Mocha" })}`,
      );
      await page.waitForFunction(() => document.documentElement.dataset.galleryReady === "1", undefined, {
        timeout: 120_000,
      });
      const chip = page.locator('button[aria-haspopup][aria-label="Model"]').first();
      const box = (await chip.boundingBox())!;
      await page.mouse.move(box.x + box.width / 2, box.y + box.height / 2);
      await page.mouse.down();
      await page.mouse.up();
      await page.locator(".acpmux-cols-list").first().waitFor();
      await page.waitForTimeout(500);
      const info = await page.evaluate(() =>
        [...document.querySelectorAll<HTMLElement>(".acpmux-cols-list")].map((list) => {
          const style = getComputedStyle(list);
          const r = list.getBoundingClientRect();
          const rows = [...list.querySelectorAll<HTMLElement>('[role="option"], [role="radio"], [role="switch"]')]
            .slice(0, 2)
            .map((row) => {
              const b = row.getBoundingClientRect();
              const at = (x: number) => {
                const hit = document.elementFromPoint(x, b.y + b.height / 2);
                return hit ? `${hit.tagName}.${String(hit.className).slice(0, 30)}` : null;
              };
              return { x: b.x, w: b.width, right: b.right, probe: at(b.right - 1), probeInt: at(Math.round(b.right - 1)) };
            });
          return {
            cls: list.className,
            left: r.left,
            right: r.right,
            offsetWidth: list.offsetWidth,
            clientWidth: list.clientWidth,
            scrollH: list.scrollHeight,
            clientH: list.clientHeight,
            padR: style.paddingRight,
            borderR: style.borderRightWidth,
            sbw: style.scrollbarWidth,
            sbPseudo: getComputedStyle(list, "::-webkit-scrollbar").width,
            rows,
          };
        }),
      );
      console.log(`PROBE3 ${engine} dpr=${await page.evaluate(() => devicePixelRatio)} ${JSON.stringify(info)}`);
      await page.close();
    });

  test("PROBE webkit rail hint", async () => {
    const page = await browsers.get("webkit")!.newPage({ viewport: { width: 1200, height: 1000 } });
    const logs: string[] = [];
    page.on("console", (m) => logs.push(`${m.type()}: ${m.text().slice(0, 200)}`));
    page.on("pageerror", (e) => logs.push(`pageerror: ${String(e).slice(0, 200)}`));
    page.on("response", (r) => {
      if (r.status() >= 400) logs.push(`http ${r.status()} ${r.url()}`);
    });
    await page.goto(
      `http://127.0.0.1:${port()}${galleryFrame("agent-pane.model-picker", { variant: "quick-menu", width: 1200, height: 1000 })}`,
    );
    await page.waitForFunction(() => document.documentElement.dataset.galleryReady === "1");
    await page.locator(".acpmux-cols-body").waitFor();
    await page.keyboard.press("Escape");
    await page.locator(".acpmux-cols").waitFor({ state: "detached" });
    await page.addStyleTag({ content: `.acpmux-model { position: fixed; left: 16px; top: 300px; margin: 0; }` });
    await page.locator(".acpmux-model .acpmux-picker-button").click();
    await page.evaluate(() => {
      const log: string[] = [];
      (window as unknown as { __log: string[] }).__log = log;
      for (const type of ["pointerover", "pointermove", "pointerout", "mousemove"])
        document.addEventListener(
          type,
          (e) => {
            const p = e as PointerEvent;
            log.push(
              `${type} ${(p.target as Element).className?.toString().slice(0, 30)} s=${p.screenX},${p.screenY} c=${p.clientX},${p.clientY} pt=${p.pointerType}`,
            );
          },
          true,
        );
    });
    const tab = page.locator('.acpmux-cols-tab[aria-label="Codex"]');
    await tab.hover();
    await page.waitForTimeout(3000);
    const state = await page.evaluate(() => ({
      tips: [...document.querySelectorAll<HTMLElement>(".ui-title-tooltip")].map(
        (t) => `${t.hidden} ${getComputedStyle(t).display} ${getComputedStyle(t).visibility} ${t.textContent}`,
      ),
      title: document.querySelector('.acpmux-cols-tab[aria-label="Codex"]')?.getAttribute("title"),
      log: (window as unknown as { __log: string[] }).__log.slice(0, 20),
    }));
    console.log(`PROBE1 ${JSON.stringify(state)} ${JSON.stringify(logs.slice(0, 20))}`);
    await page.close();
  });
});
