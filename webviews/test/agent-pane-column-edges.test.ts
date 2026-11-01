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
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";
import { requireBrowserLane } from "./support/requireBrowserLane";

type Frame = { entry: string; variant: string; edge: string; blocks: Record<string, string> };

await requireBrowserLane("agent-pane-column-edges.test.ts", async () => {
  /** The frames and, in each, the blocks that sit in the column, by selector. A chat that has sent
   *  shows no location strip (#20869). The New Tab draws its strip as text over its card, its folder
   *  icon on the field's text edge (#21133), so its frame names no block: it is here for the narrow
   *  pane's card edge (below). */
  const FRAMES: Frame[] = [
    {
      entry: "agent-pane.bottom-stack",
      variant: "trusted-permission-queue",
      edge: ".acpmux-composer-box",
      blocks: {
        transcript: ".acpmux-row:not(.acpmux-user)",
        permission: ".acpmux-asks-stack > *",
        queue: ".acpmux-composer-queue",
      },
    },
    {
      entry: "agent-pane.bottom-stack",
      variant: "trust-permission-queue",
      edge: ".acpmux-composer-box",
      blocks: {
        "trust ask": ".acpmux-trust-ask",
        queue: ".acpmux-composer-queue",
      },
    },
    {
      entry: "agent-pane.new-tab",
      variant: "empty",
      edge: ".nt-box",
      blocks: {},
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
    await warmGalleryFrame(vite, ["agent-pane.bottom-stack", "agent-pane.new-tab", "agent-pane.composer"], { browser });
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
        await page.goto(`http://127.0.0.1:${port}${galleryFrame(frame.entry, { variant: frame.variant })}`);
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
      const chat = edges[`agent-pane.bottom-stack:trusted-permission-queue @${width}`]!;
      const newTab = edges[`agent-pane.new-tab:empty @${width}`]!;
      if (Math.abs(newTab - chat) > 1) {
        offenders.push(`agent-pane.new-tab:empty @${width} card ${newTab - chat}px from the chat's`);
      }
    }
    expect({ missing, offenders }).toEqual({ missing: [], offenders: [] });
  });

  /** Runs in the page: how the block right on the card (the strip, or the queue once a chat's first
   *  send hid the strip, #20869) meets it, and the queue the block under it. */
  function joins({ edge }: { edge: string }) {
    const strip = document.querySelector(".acpmux-composer-strip");
    const queue = document.querySelector(".acpmux-composer-queue");
    const head = strip ?? queue;
    const card = document.querySelector(edge);
    if (!head || !card) return null;
    const h = head.getBoundingClientRect();
    const c = card.getBoundingClientRect();
    const radius = (el: Element, corner: string) => parseFloat(getComputedStyle(el).getPropertyValue(corner)) || 0;
    const rows = queue ? [...queue.querySelectorAll(".acpmux-queued")] : [];
    const last = rows.at(-1)?.getBoundingClientRect();
    const listBottom = queue?.getBoundingClientRect().bottom ?? 0;
    const scrolls = queue ? queue.scrollHeight - queue.clientHeight > 1 : false;
    const cap = queue ? parseFloat(getComputedStyle(queue).getPropertyValue("--acpmux-queue-max")) || 132 : 0;
    const shownLast = rows
      .map((row) => row.getBoundingClientRect().bottom)
      .filter((bottom) => bottom <= listBottom + 0.5)
      .at(-1);
    return {
      head: strip ? "strip" : "queue",
      // The block stands right on the card, side by side to the half pixel.
      left: c.left - h.left,
      right: c.right - h.right,
      gap: c.top - h.bottom,
      // Where they meet nothing rounds: a rounded corner pulls the side rim in and breaks it.
      headBottom: radius(head, "border-bottom-left-radius") + radius(head, "border-bottom-right-radius"),
      cardTop: radius(card, "border-top-left-radius") + radius(card, "border-top-right-radius"),
      // One rim goes round the strip and the card: the card's rim layer reaches up to the strip's
      // top, and the strip draws none of its own. Two rims broke at the join at 1x and took two
      // tones on focus. With no strip the layer stays on the card.
      rimTop: strip ? c.top + (parseFloat(getComputedStyle(card, "::before").top) || 0) - h.top : 0,
      stripRim: strip ? getComputedStyle(strip).boxShadow : "none",
      // Every queued prompt's text starts at one edge, right after the narrow mark column (12px in,
      // a 14px mark, an 8px gap): a "Steering" label in that column pushed every row's text right.
      textStarts: queue
        ? [...queue.querySelectorAll(".acpmux-queued-text")].map((el) =>
            Math.round(el.getBoundingClientRect().left - queue.getBoundingClientRect().left),
          )
        : [],
      // The queue's last row keeps room above what is under it: its descenders never touch it. A
      // queue past its cap scrolls and rests on a whole row (ComposerQueue fitList): the rows under
      // it are out of sight, so its last shown row ends at the list's edge. A font that wraps a
      // prompt to two lines (CI's, at 420px) takes the steering frame past its cap.
      // Past the cap only: a list that scrolls with its rows under `--acpmux-queue-max` sized short.
      scrolls,
      overCap: queue ? queue.scrollHeight > cap + 1 : false,
      queueRoom: queue && last ? Math.round(listBottom - (scrolls ? (shownLast ?? last.bottom) : last.bottom)) : null,
    };
  }

  test("the strip or queue and the card meet square in one rim, and the queue keeps room above", async () => {
    const port = (vite!.httpServer!.address() as { port: number }).port;
    const JOINS = [
      { entry: "agent-pane.composer", variant: "queued-paused", edge: ".acpmux-composer-box" },
      { entry: "agent-pane.composer", variant: "queued-steering", edge: ".acpmux-composer-box" },
      // A new chat's strip, the chat's as the New Tab's, is text a few px over its card, the card's
      // rim whole (#21133; composer-top-strip-variants.test.ts pins it), so it has no join here.
    ];
    const offenders: string[] = [];
    for (const width of WIDTHS) {
      for (const frame of JOINS) {
        const page = await browser!.newPage({ viewport: { width, height: 760 } });
        await page.goto(`http://127.0.0.1:${port}${galleryFrame(frame.entry, { variant: frame.variant })}`);
        await page.locator(frame.edge).first().waitFor({ timeout: 90_000 });
        await page.waitForFunction(() => document.documentElement.dataset.galleryReady === "1", undefined, {
          timeout: 30_000,
        });
        const join = await page.evaluate(joins, frame);
        await page.close();
        const label = `${frame.entry}:${frame.variant} @${width}`;
        if (!join) {
          offenders.push(`${label} no strip or card`);
          continue;
        }
        if (Math.abs(join.left) > 0.5 || Math.abs(join.right) > 0.5)
          offenders.push(`${label} ${join.head} sides ${join.left}/${join.right}px off the card's`);
        if (Math.abs(join.gap) > 0.5) offenders.push(`${label} ${join.head} ${join.gap}px from the card`);
        if (join.headBottom || join.cardTop)
          offenders.push(`${label} rounded join (${join.head} bottom ${join.headBottom}, card top ${join.cardTop})`);
        if (Math.abs(join.rimTop) > 0.5)
          offenders.push(`${label} card rim starts ${join.rimTop}px below the strip's top`);
        if (join.stripRim !== "none") offenders.push(`${label} strip draws its own rim (${join.stripRim})`);
        if (join.textStarts.some((x) => x > 36 || x !== join.textStarts[0]))
          offenders.push(`${label} queued text starts at ${join.textStarts.join("/")}px`);
        if (join.queueRoom !== null && (join.scrolls ? Math.abs(join.queueRoom) > 1 : join.queueRoom < 4))
          offenders.push(`${label} queue room ${join.queueRoom}px${join.scrolls ? " (scrolls)" : ""}`);
        if (join.scrolls && !join.overCap) offenders.push(`${label} queue scrolls under its cap`);
      }
    }
    expect(offenders).toEqual([]);
  });
});
