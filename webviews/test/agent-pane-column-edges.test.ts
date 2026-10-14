// Every block in the agent chat column starts on the column's left edge (Leo 2026-10-14: a
// recurring left indent on the queue and other blocks inserted over the composer). The column edge
// is the composer card's left; each block's visible left is its own box when it paints (fill,
// border or shadow), else where its first text or icon starts. Real gallery frames at a wide and
// a narrow pane; the failure lists every offender with its offset from the edge in px. A user
// bubble stands at the right, so the transcript reads the other rows.
//
// Real Chromium from Playwright; CI fails the file when it cannot launch (requireBrowserLane).
import { afterAll, beforeAll, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser } from "playwright";
import { requireBrowserLane } from "./support/requireBrowserLane";

type Frame = { entry: string; variant: string; edge: string; blocks: Record<string, string> };

await requireBrowserLane("agent-pane-column-edges.test.ts", async () => {
  /** The frames and, in each, the blocks that sit in the column, by selector. */
  const FRAMES: Frame[] = [
    {
      entry: "agent-pane.bottom-stack",
      variant: "trusted-permission-queue",
      edge: ".acpmux-composer-box",
      blocks: {
        transcript: ".acpmux-row:not(.acpmux-user)",
        permission: ".acpmux-asks-stack > *",
        queue: ".acpmux-composer-queue",
        strip: ".acpmux-composer-strip",
      },
    },
    {
      entry: "agent-pane.bottom-stack",
      variant: "trust-permission-queue",
      edge: ".acpmux-composer-box",
      blocks: {
        "trust ask": ".acpmux-trust-ask",
        "trust note": ".acpmux-composer-remote-note",
        queue: ".acpmux-composer-queue",
        strip: ".acpmux-composer-strip",
      },
    },
    {
      entry: "agent-pane.pr-dock",
      variant: "several",
      edge: ".acpmux-composer-box",
      blocks: {
        transcript: ".acpmux-row:not(.acpmux-user)",
        "PR dock": ".acpmux-pr-dock > *",
        strip: ".acpmux-composer-strip",
      },
    },
    {
      entry: "agent-pane.new-tab",
      variant: "empty",
      edge: ".nt-box",
      blocks: { strip: ".acpmux-composer-strip" },
    },
  ];
  const WIDTHS = [1100, 420];
  setDefaultTimeout(240_000);
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
  });
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });

  /** Runs in the page: each block's visible left minus the edge's left, and the edge's left. */
  function offsets({ edge, blocks }: { edge: string; blocks: Record<string, string> }) {
    const painted = (el: Element) => {
      const s = getComputedStyle(el);
      const fill = s.backgroundColor !== "rgba(0, 0, 0, 0)" && s.backgroundColor !== "transparent";
      return fill || parseFloat(s.borderLeftWidth) > 0 || s.boxShadow !== "none";
    };
    const shown = (el: Element) => {
      const s = getComputedStyle(el);
      return s.display !== "none" && s.visibility !== "hidden" && el.getBoundingClientRect().width > 0;
    };
    const visibleLeft = (el: Element) => {
      if (painted(el)) return el.getBoundingClientRect().left;
      let best = Infinity;
      const walker = document.createTreeWalker(el, NodeFilter.SHOW_ELEMENT | NodeFilter.SHOW_TEXT);
      for (let node = walker.nextNode(); node; node = walker.nextNode()) {
        if (node.nodeType === Node.TEXT_NODE) {
          if (!node.textContent?.trim()) continue;
          const range = document.createRange();
          range.selectNodeContents(node);
          const rect = range.getBoundingClientRect();
          if (rect.width) best = Math.min(best, rect.left);
        } else if (shown(node as Element) && (painted(node as Element) || (node as Element).matches("svg, img"))) {
          best = Math.min(best, (node as Element).getBoundingClientRect().left);
        }
      }
      return best;
    };
    const edgeLeft = document.querySelector(edge)!.getBoundingClientRect().left;
    const found: Record<string, number | null> = {};
    for (const [name, selector] of Object.entries(blocks)) {
      const el = [...document.querySelectorAll(selector)].find(shown);
      found[name] = el ? Math.round(visibleLeft(el) - edgeLeft) : null;
    }
    return { edgeLeft, found };
  }

  test("every block in the chat column starts on the column's left edge", async () => {
    const port = (vite!.httpServer!.address() as { port: number }).port;
    const offenders: string[] = [];
    const missing: string[] = [];
    const edges: Record<string, number> = {};
    for (const width of WIDTHS) {
      for (const frame of FRAMES) {
        const page = await browser!.newPage({ viewport: { width, height: 760 } });
        await page.goto(`http://127.0.0.1:${port}/gallery/frame.html?entry=${frame.entry}&variant=${frame.variant}`);
        // The first page waits on a cold Vite compiling the gallery, past 30 s on a busy runner.
        await page.locator(frame.edge).first().waitFor({ timeout: 90_000 });
        await page.waitForFunction(() => document.documentElement.dataset.galleryReady === "1", undefined, {
          timeout: 30_000,
        });
        const { edgeLeft, found } = await page.evaluate(offsets, frame);
        await page.close();
        const label = `${frame.entry}:${frame.variant} @${width}`;
        edges[label] = Math.round(edgeLeft);
        for (const [name, offset] of Object.entries(found)) {
          if (offset === null) missing.push(`${label} ${name}`);
          else if (Math.abs(offset) > 1) offenders.push(`${label} ${name} ${offset > 0 ? "+" : ""}${offset}px`);
        }
      }
      // In a narrow pane the New Tab card and the chat's composer card stand at the same page edge.
      if (width > 600) continue;
      const chat = edges[`agent-pane.pr-dock:several @${width}`]!;
      const newTab = edges[`agent-pane.new-tab:empty @${width}`]!;
      if (Math.abs(newTab - chat) > 1) {
        offenders.push(`agent-pane.new-tab:empty @${width} card ${newTab - chat}px from the chat's`);
      }
    }
    expect({ missing, offenders }).toEqual({ missing: [], offenders: [] });
  });
});
