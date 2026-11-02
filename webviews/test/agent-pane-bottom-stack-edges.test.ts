// cmux-web-test-timeout: 900
// l10n-allow-file: test labels, not shipped UI.
// The chat's bottom stack (Leo, 2026-10-30: "the stupid fucking gap at the bottom plus the stupid
// right indent misalignemnt"):
// - every card over the composer (the running tray, open or folded to its "Running in background"
//   header) takes the composer card's left and right x to 1px, and stands one stack gap
//   (--acpmux-stack-gap) over the composer card;
// - the stacked rows' trailing chevrons (the tray's header and each of its lines) share one x;
// - no pull request count or chip stands anywhere in the stack (cmux#29614 removed them: "remove the
//   chips they're so bad").
//
// Real gallery frames (agent-pane.bottom-stack-styles) at a wide, a normal and a narrow pane.
// With FAST_CHECKS_OUT (cmux-ci) or CMUX_BOTTOM_STACK_CAPTURE set, the measurements are written as
// geometry.json there, with 2x light and dark stills of every variant.
//
// Real Chromium from Playwright; CI fails the file when it cannot launch (requireBrowserLane).
import { afterAll, beforeAll, expect, setDefaultTimeout, test } from "bun:test";
import { mkdirSync, writeFileSync } from "node:fs";
import path from "node:path";
import { chromium, type Browser, type Page } from "playwright";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";
import { requireBrowserLane } from "./support/requireBrowserLane";

type Card = { name: string; left: number; right: number; top: number; bottom: number };
type Geometry = {
  dock: number;
  cards: Card[];
  gaps: number[];
  token: number | null;
  pullRequests: number;
  foot: number | null;
  chevrons: { name: string; x: number }[];
};

await requireBrowserLane("agent-pane-bottom-stack-edges.test.ts", async () => {
  setDefaultTimeout(840_000);
  const ENTRY = "agent-pane.bottom-stack-styles";
  const out = process.env.CMUX_BOTTOM_STACK_CAPTURE ?? process.env.FAST_CHECKS_OUT;
  const WIDTHS = [1100, 760, 420];
  /** The selected look's states, held to every rule; `cards` is measured for the record. */
  const CHECKED = ["collapsed", "no-tray", "expanded"];
  const VARIANTS = ["collapsed", "no-tray", "expanded", "cards"];
  const webviews = path.resolve(import.meta.dir, "..");
  const { createServer } = await import("vite");
  let vite: Awaited<ReturnType<typeof createServer>> | undefined;
  let browser: Browser | undefined;
  const record: Record<string, Geometry> = {};

  beforeAll(async () => {
    if (out) mkdirSync(path.join(out, "stills"), { recursive: true });
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
    if (out) writeFileSync(path.join(out, "geometry.json"), JSON.stringify(record, null, 2));
    console.log(`bottom-stack geometry: ${JSON.stringify(record)}`);
    await browser?.close();
    await vite?.close();
  });

  const url = (variant: string, width: number, theme?: string) =>
    `http://127.0.0.1:${(vite!.httpServer!.address() as { port: number }).port}${galleryFrame(ENTRY, {
      variant,
      width,
      theme,
    })}`;

  async function open(variant: string, width: number, theme?: string, scale = 1): Promise<Page> {
    const page = await browser!.newPage({ viewport: { width, height: 620 }, deviceScaleFactor: scale });
    await page.goto(url(variant, width, theme));
    await page.locator(".acpmux-composer-box").first().waitFor({ timeout: 90_000 });
    await page.waitForFunction(() => document.documentElement.dataset.galleryReady === "1", undefined, {
      timeout: 60_000,
    });
    return page;
  }

  /** Runs in the page: the stack's painted cards top to bottom, the gaps between them, any pull
   *  request control and the stacked chevrons. */
  function measure(): Geometry {
    const box = (el: Element) => el.getBoundingClientRect();
    const main = box(document.querySelector(".acpmux-main")!);
    const dock = document.querySelector(".acpmux-dock")!;
    const cards: Card[] = [];
    const add = (name: string, el: Element | null | undefined) => {
      if (!el) return;
      const r = box(el);
      if (r.width <= 0 || r.height <= 0) return;
      cards.push({ name, left: r.left, right: r.right, top: r.top, bottom: r.bottom });
    };
    add("tray", document.querySelector(".acpmux-dock > .acpmux-running-tray"));
    add("composer", document.querySelector(".acpmux-composer-box"));
    cards.sort((a, b) => a.top - b.top);
    const gaps = cards.slice(1).map((card, index) => card.top - cards[index]!.bottom);
    let token: number | null = null;
    if (getComputedStyle(dock).getPropertyValue("--acpmux-stack-gap").trim()) {
      const probe = document.createElement("div");
      probe.style.cssText = "position:absolute;visibility:hidden;height:var(--acpmux-stack-gap)";
      dock.append(probe);
      token = probe.getBoundingClientRect().height;
      probe.remove();
    }
    const foot = document.querySelector(".acpmux-composer-foot") ?? document.querySelector(".acpmux-composer-box");
    return {
      // The stack's height: from its first painted part to the pane's bottom edge.
      dock: Math.round((main.bottom - Math.min(...[...dock.children].map((part) => box(part).top))) * 10) / 10,
      cards,
      gaps,
      token,
      pullRequests: document.querySelectorAll(
        ".acpmux-pr-count, .acpmux-pr-stack, .acpmux-pr-count-host, .acpmux-pr-dock, .acpmux-pr-chip",
      ).length,
      foot: foot ? main.bottom - box(foot).bottom : null,
      // Every stacked row's trailing chevron by its glyph's center x: the tray's header and lines.
      chevrons: [
        ...[
          ...document.querySelectorAll(".acpmux-dock .acpmux-running-tray__head .acpmux-running-tray__status svg"),
        ].map((svg) => ({ name: "tray header", svg })),
        ...[...document.querySelectorAll(".acpmux-dock .acpmux-running-tray .acpmux-agent-line__chevron svg")].map(
          (svg, index) => ({ name: `tray line ${index + 1}`, svg }),
        ),
      ]
        .map(({ name, svg }) => ({ name, rect: svg.getBoundingClientRect() }))
        .filter(({ rect }) => rect.width > 0 && rect.height > 0)
        .map(({ name, rect }) => ({ name, x: (rect.left + rect.right) / 2 })),
    };
  }

  test("every bottom card shares the composer card's edges one stack gap apart, no pull request control shows, and the stacked chevrons share one x", async () => {
    const offenders: string[] = [];
    for (const width of WIDTHS) {
      for (const variant of VARIANTS) {
        const page = await open(variant, width);
        const geometry = await page.evaluate(measure);
        await page.close();
        const label = `${variant} @${width}`;
        record[label] = geometry;
        if (!CHECKED.includes(variant)) continue;
        const card = geometry.cards.find((c) => c.name === "composer");
        if (!card) {
          offenders.push(`${label}: no composer card`);
          continue;
        }
        if (variant !== "no-tray" && !geometry.cards.some((c) => c.name === "tray"))
          offenders.push(`${label}: no running tray`);
        for (const c of geometry.cards) {
          if (c.name === "composer") continue;
          const left = c.left - card.left;
          const right = c.right - card.right;
          if (Math.abs(left) > 1 || Math.abs(right) > 1)
            offenders.push(
              `${label}: ${c.name} left ${left.toFixed(1)}px, right ${right.toFixed(1)}px off the composer card`,
            );
        }
        if (geometry.token === null) offenders.push(`${label}: the dock has no --acpmux-stack-gap`);
        else
          geometry.gaps.forEach((gap, index) => {
            if (Math.abs(gap - geometry.token!) > 0.5)
              offenders.push(
                `${label}: ${geometry.cards[index]!.name} to ${geometry.cards[index + 1]!.name} gap ${gap.toFixed(1)}px, not ${geometry.token}px`,
              );
          });
        if (geometry.pullRequests)
          offenders.push(
            `${label}: ${geometry.pullRequests} pull request controls in the pane (cmux#29614 removed them)`,
          );
        const first = geometry.chevrons[0];
        for (const chevron of geometry.chevrons.slice(1))
          if (first && Math.abs(chevron.x - first.x) > 1)
            offenders.push(
              `${label}: ${chevron.name}'s chevron at x ${chevron.x.toFixed(1)}, ${first.name}'s at ${first.x.toFixed(1)}`,
            );
      }
    }
    expect(offenders).toEqual([]);
  });

  test("stills", async () => {
    if (!out) return;
    for (const variant of VARIANTS)
      for (const [theme, name] of [
        ["Apple System Colors", "dark"],
        ["Apple System Colors Light", "light"],
      ] as const) {
        const page = await open(variant, 760, theme, 2);
        await page.screenshot({ path: path.join(out, "stills", `${variant}-${name}.png`) });
        await page.close();
      }
  });
});
