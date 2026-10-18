// l10n-allow-file: test pages and diagnostic assertions.
import { expect, test } from "bun:test";
import { chromium, webkit } from "playwright";
import { previewDocument } from "../src/agent-session/acpmux/conversation/renderPreview";
import {
  RENDER_FRAME_DOC,
  RENDER_POLICY,
} from "../src/agent-session/acpmux/conversation/renderFrameShell";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("render-preview.test.ts", () => {
  for (const engine of [webkit, chromium]) {
    test(`${engine.name()} captures the shared runtime after scripts, fonts and paint`, async () => {
      const browser = await engine.launch(
        engine === chromium && process.env.CI !== "true" ? { channel: "chrome" } : {},
      );
      try {
        const page = await browser.newPage({ viewport: { width: 390, height: 1600 } });
        await page.route("https://render.test/frame", (route) =>
          route.fulfill({
            body: RENDER_FRAME_DOC,
            contentType: "text/html",
            headers: { "Content-Security-Policy": RENDER_POLICY },
          }),
        );
        const requests: string[] = [];
        await page.route("https://blocked.test/**", (route) => {
          requests.push(route.request().url());
          return route.abort();
        });
        const html = `<style>body{margin:0}.wide{width:900px}.tiny{font-size:8px}.viewport{min-height:100vh}</style>
          <h2>Preview chart</h2><div class="wide">Wide</div><p class="tiny">Tiny</p><div id="chart"></div>
          <img src="https://blocked.test/image.png"><script>
          console.warn('sample warning'); console.error('sample error');
          cmux.state.set({ready:true}).then(()=>cmux.state.get()).then(value=>console.warn('preview state '+value.ready));
          cmux.chart('#chart',{type:'bar',labels:['A','B'],series:[{name:'Count',values:[2,4]}]});
          cmux.sendPrompt('never sent').catch(e=>console.warn(e.message));
          fetch('https://blocked.test/fetch').catch(()=>console.warn('fetch blocked'));
          setTimeout(()=>{throw new Error('sample exception')},0);
          document.querySelector('h2').textContent='Scripts finished';
          </script>`;
        await page.setContent(
          previewDocument(
            html,
            "@layer cmux{:root{--cmux-text:#eee;--cmux-canvas:#191919;color-scheme:dark}body{color:var(--cmux-text)}}",
            "dark",
            true,
            "https://render.test/frame",
          ),
        );
        const result = await page.evaluate(() => (window as any).cmuxPreviewResult);
        expect(result.contentHeight).toBeGreaterThan(220);
        expect(result.warnings).toContain("Horizontal overflow");
        expect(result.warnings).toContain("1 elements wider than column");
        expect(result.warnings).toContain("1 elements with text smaller than 10px");
        expect(result.warnings).toContain("100vh usage can cause frame height feedback");
        expect(result.consoleMessages).toContainEqual({ level: "warn", message: "sample warning" });
        expect(result.consoleMessages).toContainEqual({ level: "error", message: "sample error" });
        expect(
          result.consoleMessages.some(
            (m: any) => m.level === "exception" && m.message.includes("sample exception"),
          ),
        ).toBe(true);
        expect(
          result.consoleMessages.some((m: any) =>
            m.message.includes("App actions are unavailable"),
          ),
        ).toBe(true);
        expect(result.consoleMessages).toContainEqual({ level: "warn", message: "preview state true" });
        expect(result.missingImages).toEqual(["https://blocked.test/image.png"]);
        expect(result.consoleMessages.some((m: any) => m.level === "exception" && m.message === "Resource failed to load")).toBe(false);
        expect(requests.filter((url) => url.startsWith("https://blocked.test"))).toEqual([]);
        const frame = page.frames()[1]!;
        expect(await frame.locator("h2").textContent()).toBe("Scripts finished");
        expect(await frame.locator("#chart svg").count()).toBe(1);
        expect(await frame.locator("h2").evaluate((el) => getComputedStyle(el).opacity)).toBe("1");
        expect(
          await frame.evaluate(() => {
            try {
              return !!parent.document.body;
            } catch {
              return false;
            }
          }),
        ).toBe(false);
        expect(await frame.evaluate(() => !!(window as any).webkit?.messageHandlers)).toBe(false);
      } finally {
        await browser.close();
      }
    }, 20000);

    test(`${engine.name()} measures a React commit before capture`, async () => {
      const browser = await engine.launch(engine === chromium ? { channel: "chrome" } : {});
      try {
        const page = await browser.newPage({ viewport: { width: 580, height: 1600 } });
        await page.route("https://render.test/frame", (route) => route.fulfill({
          body: RENDER_FRAME_DOC, contentType: "text/html", headers: { "Content-Security-Policy": RENDER_POLICY },
        }));
        await page.setContent(previewDocument(
          '<!-- cmux-react -->function App(){return <div style={{height:360,padding:24}}><h1>React page</h1><button>Complete button</button></div>}',
          "", "light", true, "https://render.test/frame",
        ));
        const result = await page.evaluate(() => (window as any).cmuxPreviewResult);
        expect(result.contentHeight).toBeGreaterThanOrEqual(360);
        expect(result.capturedHeight).toBe(result.contentHeight);
        expect(await page.frames()[1]!.locator("button").textContent()).toBe("Complete button");
      } finally { await browser.close(); }
    }, 20000);

    test(`${engine.name()} measures viewport and exactly 120px pages without false overflow`, async () => {
      const browser = await engine.launch(engine === chromium ? { channel: "chrome" } : {});
      try {
        const page = await browser.newPage({ viewport: { width: 390, height: 1600 } });
        await page.route("https://render.test/frame", (route) => route.fulfill({
          body: RENDER_FRAME_DOC, contentType: "text/html", headers: { "Content-Security-Policy": RENDER_POLICY },
        }));
        for (const size of ["100vh", "120px", "100%"] ) {
          const html = `<style>html,body{height:100%;margin:0}.box{height:${size};overflow:auto}.wide{width:900px}</style><div class="box"><div class="wide">Contained content</div></div>`;
          await page.setContent(previewDocument(html, "", "light", false, "https://render.test/frame"));
          const result = await page.evaluate(() => (window as any).cmuxPreviewResult);
          expect(result.contentHeight).toBe(120);
          expect(result.capturedHeight).toBe(120);
          expect(result.warnings).not.toContain("1 elements wider than column");
          expect(result.warnings).not.toContain("Horizontal overflow");
        }
      } finally { await browser.close(); }
    }, 20000);

    test(`${engine.name()} reports empty content and caps diagnostics`, async () => {
      const browser = await engine.launch(
        engine === chromium && process.env.CI !== "true" ? { channel: "chrome" } : {},
      );
      try {
        const page = await browser.newPage({ viewport: { width: 800, height: 1600 } });
        await page.route("https://render.test/frame", (route) =>
          route.fulfill({
            body: RENDER_FRAME_DOC,
            contentType: "text/html",
            headers: { "Content-Security-Policy": RENDER_POLICY },
          }),
        );
        await page.setContent(
          previewDocument(
            "<script>for(let i=0;i<100;i++)console.warn('x'.repeat(1000));</script>",
            "",
            "light",
            false,
            "https://render.test/frame",
          ),
        );
        const result = await page.evaluate(() => (window as any).cmuxPreviewResult);
        expect(result.consoleMessages).toHaveLength(50);
        expect(result.consoleMessages[0].message.length).toBe(500);
        expect(result.warnings).toContain("Zero-height page");
        expect(result.capturedHeight).toBeLessThanOrEqual(1600);
      } finally {
        await browser.close();
      }
    }, 20000);
  }
});
