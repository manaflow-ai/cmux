// cmux-web-test-timeout: 300
//
// The Background tasks panel and a workflow's side tab (Labs, summary/WorkflowSideTab.tsx) share the
// chat's right side. The side tab is a full-height overlay, so the two never show at once: opening
// Background tasks closes the side tab, and opening a side tab closes Background tasks. Before, the
// side tab stayed over the panel and left it covered and unusable.
//
// Real Chromium from Playwright on the gallery's agent pane (agent-pane.workflow-pane, a running
// workflow with Labs on); CI fails the file when it cannot launch (requireBrowserLane).
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser, type Page } from "playwright";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("background-tasks-workflow-side-tab.test.ts", async () => {
  setDefaultTimeout(240_000);
  try {
    await (await chromium.launch({ headless: true })).close();
  } catch {
    console.warn("background-tasks-workflow-side-tab: skipping (run `bunx playwright install chromium`)");
    describe.skip("background tasks and the workflow side tab", () => test("chromium", () => {}));
    return;
  }
  const ENTRY = "agent-pane.workflow-pane";
  const webviews = path.resolve(import.meta.dir, "..");
  const { createServer } = await import("vite");
  let vite: Awaited<ReturnType<typeof createServer>> | undefined;
  let browser: Browser | undefined;

  beforeAll(async () => {
    vite = await createServer({
      configFile: path.join(webviews, "vite.config.gallery-dev.ts"),
      server: { port: 0, host: "127.0.0.1", strictPort: false },
      logLevel: "error",
    });
    await vite.listen();
    browser = await chromium.launch({ headless: true });
    await warmGalleryFrame(vite, [ENTRY], { browser });
  });
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });

  const open = async (): Promise<Page> => {
    const port = (vite!.httpServer!.address() as { port: number }).port;
    const page = await browser!.newPage({ viewport: { width: 1280, height: 800 } });
    for (;;) {
      try {
        await page.goto(`http://127.0.0.1:${port}${galleryFrame(ENTRY, { variant: "running" })}`);
        await page.waitForFunction(
          () => {
            const root = document.documentElement.dataset;
            return root.galleryReady === "error" || (root.galleryReady === "1" && Boolean(root.galleryPlay));
          },
          undefined,
          { timeout: 90_000 },
        );
        break;
      } catch (error) {
        if (!/context was destroyed|navigat/i.test(String(error))) throw error;
      }
    }
    return page;
  };
  const openPanel = async (page: Page) => {
    // From the keyboard: in this frame the side tab overlays the chat's header, which the app keeps
    // clear in its shared tab row (WorkflowSideTab.css `[data-tab-row]`).
    await page.getByRole("button", { name: "Chat actions" }).focus();
    await page.keyboard.press("Enter");
    await page.getByRole("menuitem", { name: "Background tasks" }).click();
    await page.locator(".acpmux-bg").waitFor();
  };
  const openSideTab = async (page: Page) => {
    // From the keyboard too: Session Info, open in this fixture, sits beside the panel over the card.
    await page.getByRole("button", { name: "Open in side tab" }).first().focus();
    await page.keyboard.press("Enter");
    await page.locator(".acpmux-workflow-side-tab").waitFor();
  };

  test("opening Background tasks closes a workflow's side tab, and the reverse", async () => {
    const page = await open();
    try {
      await openSideTab(page);
      await openPanel(page);
      expect(await page.locator(".acpmux-workflow-side-tab").count()).toBe(0);
      // The panel is on top where it sits: what is at its middle is the panel itself.
      const probe = await page.locator(".acpmux-bg").evaluate((panel) => {
        const box = panel.getBoundingClientRect();
        const hit = document.elementFromPoint(box.left + box.width / 2, box.top + box.height / 2);
        const chain: string[] = [];
        for (let el: Element | null = hit; el && chain.length < 10; el = el.parentElement) {
          const style = getComputedStyle(el);
          chain.push(`${el.tagName.toLowerCase()}.${String(el.className).slice(0, 70)} z=${style.zIndex} pos=${style.position} pe=${style.pointerEvents} op=${style.opacity} tf=${style.transform}`);
        }
        const r = (e: Element) => { const b = e.getBoundingClientRect(); return `${b.left.toFixed(0)},${b.top.toFixed(0)} ${b.width.toFixed(0)}x${b.height.toFixed(0)}`; };
        const ps = getComputedStyle(panel);
        return {
          onTop: Boolean(hit && panel.contains(hit)),
          panel: `${r(panel)} pos=${ps.position} z=${ps.zIndex} pe=${ps.pointerEvents} op=${ps.opacity} tf=${ps.transform} anim=${ps.animationName}`,
          chain,
          siblings: [...(panel.parentElement?.children ?? [])].map((c) => `${c.tagName.toLowerCase()}.${String(c.className).slice(0, 50)} ${r(c)} z=${getComputedStyle(c).zIndex} pos=${getComputedStyle(c).position}`),
        };
      });
      if (!probe.onTop) console.log("PROBE " + JSON.stringify(probe, null, 1));
      expect(probe.onTop).toBe(true);
      await openSideTab(page);
      expect(await page.locator(".acpmux-bg").count()).toBe(0);
    } finally {
      await page.close();
    }
  });
});
